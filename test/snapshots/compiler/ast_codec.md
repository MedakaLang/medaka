# META
source_lines=1790
stages=DESUGAR,MARK
# SOURCE
-- A faithful, fail-closed codec for the elaborated AST and the evidence rows.
--
-- The writer produces an `SExp`; the reader consumes a `SexpCursor` straight
-- off the bytes, so no intermediate `SExp` is built. The encoding is compact:
-- a type's constructors are numbered in declaration order (`(k field...)`, or
-- the bare `k` for a constructor with no fields); a type with one constructor
-- is just its fields in a list; a placeholder `Loc` is `z`; an `EvId` or
-- `BinderId` of module `""` is its bare ordinal; a `Bool` is `t` or `f`; a
-- `Float` is the two 32-bit halves of its IEEE 754 bits as a pair, so NaN
-- payloads and signed zeros survive.
--
-- Every writer match is exhaustive with no wildcard arm, so a new constructor
-- in `frontend.ast` stops this module compiling until it is given a tag.
-- A reader refuses an unknown tag, a bare tag that names a constructor with
-- fields, a tagged form that names one without, truncation and a trailing
-- node; the cursor records the first refusal and `readDecls` and
-- `readEvEntries` turn it into an `Err` rather than a half-read value.

import frontend.ast.*
import array.{fromList}
import list.{splitAt}
import support.sexp_value.{
  SExp(..), SexpCursor, SexpError(..), cursorAdvance, cursorAtEnd, cursorAtom,
  cursorClose, cursorFail, cursorFailed, cursorInt, cursorList, cursorOf,
  cursorOffset, cursorOpen, cursorPeek, cursorChar
}

-- ── entry points ────────────────────────────────────────────────────────────

export
declsSExp : List Decl -> SExp
declsSExp ds = sexpList sexpDecl ds

export
evEntriesSExp : List EvEntry -> SExp
evEntriesSExp es = sexpList sexpEvEntry es

-- Reads one list of declarations; the caller decides what may follow it.
export
readDecls : SexpCursor -> Result SexpError (List Decl)
readDecls cur = checked "decls" cur (cursorList readDecl cur)

-- Reads one list of evidence rows; the caller decides what may follow it.
export
readEvEntries : SexpCursor -> Result SexpError (List EvEntry)
readEvEntries cur = checked "evidence" cur (cursorList readEvEntry cur)

-- The whole of `text` is one list of declarations.
export
decodeDecls : String -> Result SexpError (List Decl)
decodeDecls text = decodeAll readDecls text

-- The whole of `text` is one list of evidence rows.
export
decodeEvEntries : String -> Result SexpError (List EvEntry)
decodeEvEntries text = decodeAll readEvEntries text

decodeAll : (SexpCursor -> Result SexpError a) -> String -> Result SexpError a
decodeAll reader text =
  let cur = cursorOf text
  match reader cur
    Err e => Err e
    Ok v =>
      if cursorAtEnd cur then
        Ok v
      else
        Err SexpError {
          seOffset = cursorOffset cur,
          sePath = "",
          seWhat = "trailing text after the encoded value",
        }

checked : String -> SexpCursor -> a -> Result SexpError a
checked path cur v =
  if cursorFailed cur then
    Err SexpError {
      seOffset = cursorOffset cur,
      sePath = path,
      seWhat = "malformed or truncated encoding",
    }
  else
    Ok v

-- ── building blocks ────────────────────────────────────────────────────────

sexpInt : Int -> SExp
sexpInt n = SAtom (intToString n)

sexpString : String -> SExp
sexpString s = SAtom s

export
sexpBool : Bool -> SExp
sexpBool b = SAtom (if b then "t" else "f")

sexpFloat : Float -> SExp
sexpFloat f = match splitAt 4 (toList (floatToBytes64 f))
  (hi, lo) => SList [sexpInt (wordOf hi), sexpInt (wordOf lo)]

sexpList : (a -> SExp) -> List a -> SExp
sexpList f xs = SList (map f xs)

sexpOpt : (a -> SExp) -> Option a -> SExp
sexpOpt _ None = SList []
sexpOpt f (Some x) = SList [f x]

sexpPair : (a -> SExp) -> (b -> SExp) -> (a, b) -> SExp
sexpPair fa fb (a, b) = SList [fa a, fb b]

sexpLoc : Loc -> SExp
sexpLoc (Loc "" 1 0 1 0) = SAtom "z"
sexpLoc (Loc f a b c d) =
  SList [SAtom f, sexpInt a, sexpInt b, sexpInt c, sexpInt d]

sexpEvId : EvId -> SExp
sexpEvId (EvId "" n) = sexpInt n
sexpEvId (EvId m n) = SList [SAtom m, sexpInt n]

export
sexpBinderId : BinderId -> SExp
sexpBinderId (BinderId "" n) = sexpInt n
sexpBinderId (BinderId m n) = SList [SAtom m, sexpInt n]

-- Big-endian bytes as the number they spell.
wordOf : List Int -> Int
wordOf bytes = fold (acc b => acc * 256 + b) 0 bytes

-- The four big-endian bytes of a 32-bit number.
bytesOfWord : Int -> List Int
bytesOfWord w = [w / 16777216 % 256, w / 65536 % 256, w / 256 % 256, w % 256]

readInt : SexpCursor -> Int
readInt cur = cursorInt cur

readString : SexpCursor -> String
readString cur = cursorAtom cur

export
readBool : SexpCursor -> Bool
readBool cur =
  let c = cursorChar cur
  if c == 116 then True else if c == 102 then False else cursorFail cur False

readFloat : SexpCursor -> Float
readFloat cur =
  let _ = cursorOpen cur
  let hi = cursorInt cur
  let lo = cursorInt cur
  let _ = cursorClose cur
  if hi < 0 || hi > 4294967295 || lo < 0 || lo > 4294967295 then
    cursorFail cur 0.0
  else
    bytesToFloat64 (fromList (bytesOfWord hi ++ bytesOfWord lo)) 0

readOpt : (SexpCursor -> a) -> SexpCursor -> Option a
readOpt f cur =
  let _ = cursorOpen cur
  if cursorPeek cur == 41 then
    let _ = cursorAdvance cur
    None
  else
    let v = f cur
    let _ = cursorClose cur
    Some v

readPair : (SexpCursor -> a) -> (SexpCursor -> b) -> SexpCursor -> (a, b)
readPair fa fb cur =
  let _ = cursorOpen cur
  let a = fa cur
  let b = fb cur
  let _ = cursorClose cur
  (a, b)

readLoc : SexpCursor -> Loc
readLoc cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let f = readString cur
    let a = readInt cur
    let b = readInt cur
    let c = readInt cur
    let d = readInt cur
    let _ = cursorClose cur
    Loc f a b c d
  else if cursorChar cur == 122 then
    Loc "" 1 0 1 0
  else
    cursorFail cur dfltLoc

readEvId : SexpCursor -> EvId
readEvId cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let m = readString cur
    let n = readInt cur
    let _ = cursorClose cur
    EvId m n
  else
    EvId "" (readInt cur)

export
readBinderId : SexpCursor -> BinderId
readBinderId cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let m = readString cur
    let n = readInt cur
    let _ = cursorClose cur
    BinderId m n
  else
    BinderId "" (readInt cur)

-- ── writers ────────────────────────────────────────────────────────────────

sexpLit : Lit -> SExp
sexpLit (LInt a0) = SList [SAtom "0", sexpInt a0]
sexpLit (LFloat a0) = SList [SAtom "1", sexpFloat a0]
sexpLit (LU64 a0 a1) = SList [SAtom "2", sexpInt a0, sexpInt a1]
sexpLit (LI64 a0 a1) = SList [SAtom "3", sexpInt a0, sexpInt a1]
sexpLit (LString a0) = SList [SAtom "4", sexpString a0]
sexpLit (LChar a0) = SList [SAtom "5", sexpString a0]
sexpLit (LBool a0) = SList [SAtom "6", sexpBool a0]
sexpLit LUnit = SAtom "7"

sexpTyConOrigin : TyConOrigin -> SExp
sexpTyConOrigin OriginUnresolved = SAtom "0"
sexpTyConOrigin OriginBuiltin = SAtom "1"
sexpTyConOrigin (OriginModule a0) = SList [SAtom "2", sexpString a0]

sexpTy : Ty -> SExp
sexpTy (TyCon { tyConName = a0, tyConLoc = a1, tyConOrigin = a2 }) =
  SList [SAtom "0", sexpString a0, sexpOpt sexpLoc a1, sexpTyConOrigin a2]
sexpTy (TyVar a0) = SList [SAtom "1", sexpString a0]
sexpTy (TyApp a0 a1) = SList [SAtom "2", sexpTy a0, sexpTy a1]
sexpTy (TyFun a0 a1) = SList [SAtom "3", sexpTy a0, sexpTy a1]
sexpTy (TyTuple a0) = SList [SAtom "4", sexpList sexpTy a0]
sexpTy (TyEffect a0 a1 a2) = SList [
  SAtom "5",
  sexpList sexpEffAtomTy a0,
  sexpList sexpString a1,
  sexpTy a2,
]
sexpTy (TyConstrained a0 a1) =
  SList [SAtom "6", sexpList sexpConstraint a0, sexpTy a1]
sexpTy (TyNamed a0 a1 a2) =
  SList [SAtom "7", sexpString a0, sexpTy a1, sexpOpt sexpEffAtomTy a2]
sexpTy (TyQual a0 a1 a2) =
  SList [SAtom "8", sexpTy a0, sexpList sexpEffParamTy a1, sexpOpt sexpLoc a2]
sexpTy (TyRow a0 a1 a2) = SList [
  SAtom "9",
  sexpList sexpEffAtomTy a0,
  sexpList sexpString a1,
  sexpOpt sexpLoc a2,
]
sexpTy (TyAuth a0 a1) =
  SList [SAtom "10", sexpList sexpEffParamTy a0, sexpOpt sexpLoc a1]

sexpEffAtomTy : EffAtomTy -> SExp
sexpEffAtomTy (EffAtomTy { eatLabel = a0, eatOrigin = a1, eatParam = a2, eatLoc = a3, eatPattern = a4 }) = SList
  [
    sexpString a0,
    sexpTyConOrigin a1,
    sexpEffParamTy a2,
    sexpOpt sexpLoc a3,
    sexpBool a4,
  ]

sexpEffParamTy : EffParamTy -> SExp
sexpEffParamTy EPTop = SAtom "0"
sexpEffParamTy (EPLit a0) = SList [SAtom "1", sexpString a0]
sexpEffParamTy (EPName a0) = SList [SAtom "2", sexpString a0]
sexpEffParamTy (EPSet a0) = SList [SAtom "3", sexpList sexpString a0]
sexpEffParamTy (EPProduct a0) =
  SList [SAtom "4", sexpList (sexpPair sexpString sexpEffParamTy) a0]

sexpConstraint : Constraint -> SExp
sexpConstraint (Constraint { constraintHead = a0, constraintArgs = a1, constraintOrigin = a2 }) =
  SList [sexpString a0, sexpList sexpTy a1, sexpTyConOrigin a2]

sexpKindAnn : KindAnn -> SExp
sexpKindAnn KindType = SAtom "0"
sexpKindAnn KindEffect = SAtom "1"
sexpKindAnn (KindAuthority a0 a1 a2 a3) = SList [
  SAtom "2",
  sexpString a0,
  sexpTyConOrigin a1,
  sexpBool a2,
  sexpOpt sexpLoc a3,
]
sexpKindAnn (KindArrow a0 a1) =
  SList [SAtom "3", sexpKindAnn a0, sexpKindAnn a1]

sexpRoute : Route -> SExp
sexpRoute RNone = SAtom "0"
sexpRoute (RKey a0 a1 a2) =
  SList [SAtom "1", sexpString a0, sexpList sexpRoute a1, sexpList sexpRoute a2]
sexpRoute (RDict a0) = SList [SAtom "2", sexpString a0]
sexpRoute (RDictFwd a0) = SList [SAtom "3", sexpString a0]
sexpRoute (RLocal a0 a1) =
  SList [SAtom "4", sexpString a0, sexpList sexpRoute a1]
sexpRoute (RScalar a0) = SList [SAtom "5", sexpString a0]
sexpRoute (RProj a0 a1) = SList [SAtom "6", sexpRoute a0, sexpList sexpInt a1]

sexpEvVal : EvVal -> SExp
sexpEvVal (EvOne a0) = SList [SAtom "0", sexpRoute a0]
sexpEvVal (EvMany a0) = SList [SAtom "1", sexpList sexpRoute a0]
sexpEvVal (EvMethod a0 a1 a2 a3 a4) = SList [
  SAtom "2",
  sexpString a0,
  sexpInt a1,
  sexpRoute a2,
  sexpList sexpRoute a3,
  sexpList sexpRoute a4,
]
sexpEvVal (EvLit a0 a1) = SList [SAtom "3", sexpOpt sexpFloat a0, sexpRoute a1]
sexpEvVal (EvHead a0) = SList [SAtom "4", sexpString a0]

sexpEvEntry : EvEntry -> SExp
sexpEvEntry (EvEntry a0 a1) = SList [sexpEvId a0, sexpEvVal a1]

sexpAddr : Addr -> SExp
sexpAddr (ALocal a0 a1) = SList [SAtom "0", sexpInt a0, sexpInt a1]
sexpAddr AGlobal = SAtom "1"

sexpPat : Pat -> SExp
sexpPat (PVar a0 a1 a2) =
  SList [SAtom "0", sexpString a0, sexpLoc a1, sexpBinderId a2]
sexpPat PWild = SAtom "1"
sexpPat (PLit a0) = SList [SAtom "2", sexpLit a0]
sexpPat (PCon a0 a1) = SList [SAtom "3", sexpString a0, sexpList sexpPat a1]
sexpPat (PCons a0 a1) = SList [SAtom "4", sexpPat a0, sexpPat a1]
sexpPat (PTuple a0) = SList [SAtom "5", sexpList sexpPat a0]
sexpPat (PList a0) = SList [SAtom "6", sexpList sexpPat a0]
sexpPat (PAs a0 a1 a2 a3) =
  SList [SAtom "7", sexpString a0, sexpLoc a1, sexpBinderId a2, sexpPat a3]
sexpPat (PRng a0 a1 a2) = SList [SAtom "8", sexpLit a0, sexpLit a1, sexpBool a2]
sexpPat (PRec a0 a1 a2) =
  SList [SAtom "9", sexpString a0, sexpList sexpRecPatField a1, sexpBool a2]

sexpRecPatField : RecPatField -> SExp
sexpRecPatField (RecPatField a0 a1 a2 a3) =
  SList [sexpString a0, sexpLoc a1, sexpBinderId a2, sexpOpt sexpPat a3]

sexpGuard : Guard -> SExp
sexpGuard (GBool a0) = SList [SAtom "0", sexpExpr a0]
sexpGuard (GBind a0 a1) = SList [SAtom "1", sexpPat a0, sexpExpr a1]

sexpArm : Arm -> SExp
sexpArm (Arm a0 a1 a2) = SList [sexpPat a0, sexpList sexpGuard a1, sexpExpr a2]

sexpDoStmt : DoStmt -> SExp
sexpDoStmt (DoExpr a0) = SList [SAtom "0", sexpExpr a0]
sexpDoStmt (DoBind a0 a1) = SList [SAtom "1", sexpPat a0, sexpExpr a1]
sexpDoStmt (DoLet a0 a1 a2 a3 a4) = SList [
  SAtom "2",
  sexpBool a0,
  sexpBool a1,
  sexpPat a2,
  sexpExpr a3,
  sexpLoc a4,
]
sexpDoStmt (DoAssign a0 a1) = SList [SAtom "3", sexpString a0, sexpExpr a1]
sexpDoStmt (DoFieldAssign a0 a1 a2) =
  SList [SAtom "4", sexpString a0, sexpList sexpString a1, sexpExpr a2]

sexpInterpPart : InterpPart -> SExp
sexpInterpPart (InterpStr a0) = SList [SAtom "0", sexpString a0]
sexpInterpPart (InterpExpr a0) = SList [SAtom "1", sexpExpr a0]

sexpGuardArm : GuardArm -> SExp
sexpGuardArm (GuardArm a0 a1) = SList [sexpList sexpGuard a0, sexpExpr a1]

sexpFieldAssign : FieldAssign -> SExp
sexpFieldAssign (FieldAssign a0 a1) = SList [sexpString a0, sexpExpr a1]

sexpSection : Section -> SExp
sexpSection (SecBare a0) = SList [SAtom "0", sexpString a0]
sexpSection (SecRight a0 a1) = SList [SAtom "1", sexpString a0, sexpExpr a1]
sexpSection (SecLeft a0 a1) = SList [SAtom "2", sexpExpr a0, sexpString a1]

sexpFunClause : FunClause -> SExp
sexpFunClause (FunClause a0 a1) = SList [sexpList sexpPat a0, sexpExpr a1]

sexpLetBind : LetBind -> SExp
sexpLetBind (LetBind a0 a1 a2 a3) =
  SList [sexpString a0, sexpList sexpFunClause a1, sexpLoc a2, sexpBinderId a3]

sexpExpr : Expr -> SExp
sexpExpr (ELit a0) = SList [SAtom "0", sexpLit a0]
sexpExpr (EVar a0) = SList [SAtom "1", sexpString a0]
sexpExpr (EApp a0 a1) = SList [SAtom "2", sexpExpr a0, sexpExpr a1]
sexpExpr (ELam a0 a1) = SList [SAtom "3", sexpList sexpPat a0, sexpExpr a1]
sexpExpr (ELet a0 a1 a2 a3 a4) = SList [
  SAtom "4",
  sexpLoc a0,
  sexpBool a1,
  sexpPat a2,
  sexpExpr a3,
  sexpExpr a4,
]
sexpExpr (EMatch a0 a1) = SList [SAtom "5", sexpExpr a0, sexpList sexpArm a1]
sexpExpr (EIf a0 a1 a2) =
  SList [SAtom "6", sexpExpr a0, sexpExpr a1, sexpExpr a2]
sexpExpr (EBinOp a0 a1 a2 a3) =
  SList [SAtom "7", sexpString a0, sexpExpr a1, sexpExpr a2, sexpEvId a3]
sexpExpr (EUnOp a0 a1 a2) =
  SList [SAtom "8", sexpString a0, sexpExpr a1, sexpEvId a2]
sexpExpr (EInfix a0 a1 a2) =
  SList [SAtom "9", sexpString a0, sexpExpr a1, sexpExpr a2]
sexpExpr (EFieldAccess a0 a1 a2) =
  SList [SAtom "10", sexpExpr a0, sexpString a1, sexpEvId a2]
sexpExpr (ETuple a0) = SList [SAtom "11", sexpList sexpExpr a0]
sexpExpr (EListLit a0) = SList [SAtom "12", sexpList sexpExpr a0]
sexpExpr (EArrayLit a0) = SList [SAtom "13", sexpList sexpExpr a0]
sexpExpr (ERangeList a0 a1 a2) =
  SList [SAtom "14", sexpExpr a0, sexpExpr a1, sexpBool a2]
sexpExpr (ERangeArray a0 a1 a2) =
  SList [SAtom "15", sexpExpr a0, sexpExpr a1, sexpBool a2]
sexpExpr (ESlice a0 a1 a2 a3) =
  SList [SAtom "16", sexpExpr a0, sexpExpr a1, sexpExpr a2, sexpBool a3]
sexpExpr (ELetGroup a0 a1) =
  SList [SAtom "17", sexpList sexpLetBind a0, sexpExpr a1]
sexpExpr (ESection a0) = SList [SAtom "18", sexpSection a0]
sexpExpr (EIndex a0 a1) = SList [SAtom "19", sexpExpr a0, sexpExpr a1]
sexpExpr (EAnnot a0 a1) = SList [SAtom "20", sexpExpr a0, sexpTy a1]
sexpExpr (EHeadAnnot a0 a1) = SList [SAtom "21", sexpExpr a0, sexpTy a1]
sexpExpr (EBlock a0) = SList [SAtom "22", sexpList sexpDoStmt a0]
sexpExpr (EDo a0 a1) = SList [SAtom "23", sexpBool a0, sexpList sexpDoStmt a1]
sexpExpr (EStringInterp a0) = SList [SAtom "24", sexpList sexpInterpPart a0]
sexpExpr (EGuards a0) = SList [SAtom "25", sexpList sexpGuardArm a0]
sexpExpr (ERecordCreate a0 a1) =
  SList [SAtom "26", sexpString a0, sexpList sexpFieldAssign a1]
sexpExpr (ERecordUpdate a0 a1 a2) =
  SList [SAtom "27", sexpExpr a0, sexpList sexpFieldAssign a1, sexpEvId a2]
sexpExpr (EVariantUpdate a0 a1 a2) =
  SList [SAtom "28", sexpString a0, sexpExpr a1, sexpList sexpFieldAssign a2]
sexpExpr (EMapLit a0 a1) =
  SList [SAtom "29", sexpString a0, sexpList (sexpPair sexpExpr sexpExpr) a1]
sexpExpr (ESetLit a0 a1) =
  SList [SAtom "30", sexpString a0, sexpList sexpExpr a1]
sexpExpr (EAsPat a0 a1) = SList [SAtom "31", sexpString a0, sexpExpr a1]
sexpExpr (EMethodRef a0) = SList [SAtom "32", sexpString a0]
sexpExpr (EDictApp a0) = SList [SAtom "33", sexpString a0]
sexpExpr (EVarAt a0 a1) = SList [SAtom "34", sexpString a0, sexpAddr a1]
sexpExpr (EVarId a0 a1) = SList [SAtom "35", sexpString a0, sexpInt a1]
sexpExpr (EMethodAt a0 a1 a2) =
  SList [SAtom "36", sexpString a0, sexpString a1, sexpEvId a2]
sexpExpr (EDictAt a0 a1) = SList [SAtom "37", sexpString a0, sexpEvId a1]
sexpExpr (ELoc a0 a1) = SList [SAtom "38", sexpLoc a0, sexpExpr a1]
sexpExpr (EDoOrigin a0 a1) = SList [SAtom "39", sexpLoc a0, sexpExpr a1]
sexpExpr (ENumLit a0 a1 a2) =
  SList [SAtom "40", sexpInt a0, sexpEvId a1, sexpString a2]
sexpExpr (EWideLit a0 a1 a2 a3) =
  SList [SAtom "41", sexpInt a0, sexpInt a1, sexpEvId a2, sexpString a3]

sexpUseMember : UseMember -> SExp
sexpUseMember (UseMember a0 a1 a2 a3) =
  SList [sexpString a0, sexpBool a1, sexpLoc a2, sexpOpt sexpString a3]

sexpUsePath : UsePath -> SExp
sexpUsePath (UseName a0) = SList [SAtom "0", sexpList sexpString a0]
sexpUsePath (UseGroup a0 a1) =
  SList [SAtom "1", sexpList sexpString a0, sexpList sexpUseMember a1]
sexpUsePath (UseWild a0) = SList [SAtom "2", sexpList sexpString a0]
sexpUsePath (UseAlias a0 a1) =
  SList [SAtom "3", sexpList sexpString a0, sexpString a1]

sexpPropParam : PropParam -> SExp
sexpPropParam (PropParam a0 a1 a2) =
  SList [sexpString a0, sexpLoc a1, sexpTy a2]

sexpMethodDefault : MethodDefault -> SExp
sexpMethodDefault (MethodDefault a0 a1) =
  SList [sexpList sexpPat a0, sexpExpr a1]

sexpIfaceMethod : IfaceMethod -> SExp
sexpIfaceMethod (IfaceMethod a0 a1 a2 a3) = SList [
  sexpString a0,
  sexpTy a1,
  sexpOpt sexpMethodDefault a2,
  sexpOpt sexpLoc a3,
]

sexpSuper : Super -> SExp
sexpSuper (Super { superHead = a0, superParams = a1, superOrigin = a2 }) =
  SList [sexpString a0, sexpList sexpString a1, sexpTyConOrigin a2]

sexpRequire : Require -> SExp
sexpRequire (Require { requireHead = a0, requireArgs = a1, requireOrigin = a2 }) =
  SList [sexpString a0, sexpList sexpTy a1, sexpTyConOrigin a2]

sexpImplMethod : ImplMethod -> SExp
sexpImplMethod (ImplMethod a0 a1 a2) =
  SList [sexpString a0, sexpList sexpPat a1, sexpExpr a2]

sexpDataVis : DataVis -> SExp
sexpDataVis VisPrivate = SAtom "0"
sexpDataVis VisAbstract = SAtom "1"
sexpDataVis VisPublic = SAtom "2"

sexpField : Field -> SExp
sexpField (Field a0 a1) = SList [sexpString a0, sexpTy a1]

sexpConPayload : ConPayload -> SExp
sexpConPayload (ConPos a0) = SList [SAtom "0", sexpList sexpTy a0]
sexpConPayload (ConNamed a0 a1) =
  SList [SAtom "1", sexpList sexpField a0, sexpBool a1]

sexpVariant : Variant -> SExp
sexpVariant (Variant a0 a1) = SList [sexpString a0, sexpConPayload a1]

sexpAttr : Attr -> SExp
sexpAttr (AttrDeprecated a0) = SList [SAtom "0", sexpOpt sexpString a0]
sexpAttr AttrInline = SAtom "1"
sexpAttr AttrMustUse = SAtom "2"
sexpAttr AttrNoInline = SAtom "3"

sexpDeriveRef : DeriveRef -> SExp
sexpDeriveRef (DeriveRef a0 a1) = SList [sexpString a0, sexpOpt sexpLoc a1]

sexpExternDecl : ExternDecl -> SExp
sexpExternDecl (ExternDecl { edPub = a0, edName = a1, edTy = a2, edLoc = a3, edBinds = a4 }) = SList
  [
    sexpBool a0,
    sexpString a1,
    sexpTy a2,
    sexpLoc a3,
    sexpList sexpExternBind a4,
  ]

sexpExternBind : ExternBind -> SExp
sexpExternBind (ExternBind { ebHost = a0, ebSymbol = a1, ebLoc = a2 }) =
  SList [sexpString a0, sexpString a1, sexpLoc a2]

sexpDecl : Decl -> SExp
sexpDecl (DTypeSig a0 a1 a2 a3) =
  SList [SAtom "0", sexpBool a0, sexpString a1, sexpTy a2, sexpLoc a3]
sexpDecl (DExtern a0) = SList [SAtom "1", sexpExternDecl a0]
sexpDecl (DFunDef a0 a1 a2 a3 a4 a5) = SList [
  SAtom "2",
  sexpBool a0,
  sexpString a1,
  sexpList sexpPat a2,
  sexpExpr a3,
  sexpLoc a4,
  sexpBinderId a5,
]
sexpDecl (DData { dataVis = a0, dataName = a1, dataParams = a2, dataParamKinds = a3, dataCtors = a4, dataCtorBinders = a5, dataDerives = a6, dataOrigin = a7, dataExtern = a8, dataNameLoc = a9 }) = SList
  [
    SAtom "3",
    sexpDataVis a0,
    sexpString a1,
    sexpList sexpString a2,
    sexpList (sexpOpt sexpKindAnn) a3,
    sexpList sexpVariant a4,
    sexpList (sexpList (sexpPair sexpString sexpKindAnn)) a5,
    sexpList sexpDeriveRef a6,
    sexpTyConOrigin a7,
    sexpBool a8,
    sexpOpt sexpLoc a9,
  ]
sexpDecl (DUse a0 a1 a2) =
  SList [SAtom "4", sexpBool a0, sexpUsePath a1, sexpLoc a2]
sexpDecl (DEffect a0 a1 a2 a3 a4 a5) = SList [
  SAtom "5",
  sexpBool a0,
  sexpString a1,
  sexpOpt sexpString a2,
  sexpList (sexpPair sexpString sexpString) a3,
  sexpTyConOrigin a4,
  sexpOpt sexpLoc a5,
]
sexpDecl (DProp a0 a1 a2 a3) = SList [
  SAtom "6",
  sexpBool a0,
  sexpString a1,
  sexpList sexpPropParam a2,
  sexpExpr a3,
]
sexpDecl (DTest a0 a1 a2) =
  SList [SAtom "7", sexpBool a0, sexpString a1, sexpExpr a2]
sexpDecl (DInterface { pub = a0, def = a1, name = a2, typarams = a3, typaramKinds = a4, supers = a5, methods = a6, ifaceOrigin = a7, ifaceNameLoc = a8 }) = SList
  [
    SAtom "8",
    sexpBool a0,
    sexpBool a1,
    sexpString a2,
    sexpList sexpString a3,
    sexpList (sexpOpt sexpKindAnn) a4,
    sexpList sexpSuper a5,
    sexpList sexpIfaceMethod a6,
    sexpTyConOrigin a7,
    sexpOpt sexpLoc a8,
  ]
sexpDecl (DImpl { pub = a0, iface = a1, tys = a2, reqs = a3, methods = a4, implOrigin = a5, implIfaceLoc = a6 }) = SList
  [
    SAtom "9",
    sexpBool a0,
    sexpString a1,
    sexpList sexpTy a2,
    sexpList sexpRequire a3,
    sexpList sexpImplMethod a4,
    sexpTyConOrigin a5,
    sexpOpt sexpLoc a6,
  ]
sexpDecl (DTypeAlias { tyAliasPub = a0, tyAliasName = a1, tyAliasParams = a2, tyAliasParamKinds = a3, tyAliasRhs = a4, tyAliasOrigin = a5, tyAliasNameLoc = a6 }) = SList
  [
    SAtom "10",
    sexpBool a0,
    sexpString a1,
    sexpList sexpString a2,
    sexpList (sexpOpt sexpKindAnn) a3,
    sexpTy a4,
    sexpTyConOrigin a5,
    sexpOpt sexpLoc a6,
  ]
sexpDecl (DNewtype { newtypePub = a0, newtypeName = a1, newtypeParams = a2, newtypeParamKinds = a3, newtypeCtor = a4, newtypeCtorBinders = a5, newtypeFieldTy = a6, newtypeDerives = a7, newtypeOrigin = a8, newtypeNameLoc = a9 }) = SList
  [
    SAtom "11",
    sexpBool a0,
    sexpString a1,
    sexpList sexpString a2,
    sexpList (sexpOpt sexpKindAnn) a3,
    sexpString a4,
    sexpList (sexpPair sexpString sexpKindAnn) a5,
    sexpTy a6,
    sexpList sexpDeriveRef a7,
    sexpTyConOrigin a8,
    sexpOpt sexpLoc a9,
  ]
sexpDecl (DLetGroup a0 a1) =
  SList [SAtom "12", sexpBool a0, sexpList sexpLetBind a1]
sexpDecl (DAttrib a0 a1) = SList [SAtom "13", sexpList sexpAttr a0, sexpDecl a1]

-- ── placeholders for a refused read ────────────────────────────────────────
-- A reader that refuses still has to return a value of its type; the cursor's
-- failure is what the caller reads, and the value is never used.

dfltLoc : Loc
dfltLoc = Loc "" 1 0 1 0

dfltLit : Lit
dfltLit = LUnit

dfltTyConOrigin : TyConOrigin
dfltTyConOrigin = OriginUnresolved

dfltTy : Ty
dfltTy =
  TyCon { tyConName = "", tyConLoc = None, tyConOrigin = dfltTyConOrigin }

dfltEffParamTy : EffParamTy
dfltEffParamTy = EPTop

dfltKindAnn : KindAnn
dfltKindAnn = KindType

dfltRoute : Route
dfltRoute = RNone

dfltEvVal : EvVal
dfltEvVal = EvOne dfltRoute

dfltAddr : Addr
dfltAddr = AGlobal

dfltPat : Pat
dfltPat = PWild

dfltGuard : Guard
dfltGuard = GBool dfltExpr

dfltDoStmt : DoStmt
dfltDoStmt = DoExpr dfltExpr

dfltInterpPart : InterpPart
dfltInterpPart = InterpStr ""

dfltSection : Section
dfltSection = SecBare ""

dfltExpr : Expr
dfltExpr = ELit dfltLit

dfltUsePath : UsePath
dfltUsePath = UseName []

dfltDataVis : DataVis
dfltDataVis = VisPrivate

dfltConPayload : ConPayload
dfltConPayload = ConPos []

dfltAttr : Attr
dfltAttr = AttrInline

dfltDecl : Decl
dfltDecl = DTypeSig False "" dfltTy dfltLoc

-- ── readers ────────────────────────────────────────────────────────────────

readLit : SexpCursor -> Lit
readLit cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let v = readLitTagged (cursorInt cur) cur
    let _ = cursorClose cur
    v
  else
    readLitBare (cursorInt cur) cur

readLitBare : Int -> SexpCursor -> Lit
readLitBare 7 _ = LUnit
readLitBare _ cur = cursorFail cur dfltLit

readLitTagged : Int -> SexpCursor -> Lit
readLitTagged 0 cur =
  let a0 = readInt cur
  LInt a0
readLitTagged 1 cur =
  let a0 = readFloat cur
  LFloat a0
readLitTagged 2 cur =
  let a0 = readInt cur
  let a1 = readInt cur
  LU64 a0 a1
readLitTagged 3 cur =
  let a0 = readInt cur
  let a1 = readInt cur
  LI64 a0 a1
readLitTagged 4 cur =
  let a0 = readString cur
  LString a0
readLitTagged 5 cur =
  let a0 = readString cur
  LChar a0
readLitTagged 6 cur =
  let a0 = readBool cur
  LBool a0
readLitTagged _ cur = cursorFail cur dfltLit

readTyConOrigin : SexpCursor -> TyConOrigin
readTyConOrigin cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let v = readTyConOriginTagged (cursorInt cur) cur
    let _ = cursorClose cur
    v
  else
    readTyConOriginBare (cursorInt cur) cur

readTyConOriginBare : Int -> SexpCursor -> TyConOrigin
readTyConOriginBare 0 _ = OriginUnresolved
readTyConOriginBare 1 _ = OriginBuiltin
readTyConOriginBare _ cur = cursorFail cur dfltTyConOrigin

readTyConOriginTagged : Int -> SexpCursor -> TyConOrigin
readTyConOriginTagged 2 cur =
  let a0 = readString cur
  OriginModule a0
readTyConOriginTagged _ cur = cursorFail cur dfltTyConOrigin

readTy : SexpCursor -> Ty
readTy cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let v = readTyTagged (cursorInt cur) cur
    let _ = cursorClose cur
    v
  else
    readTyBare (cursorInt cur) cur

readTyBare : Int -> SexpCursor -> Ty
readTyBare _ cur = cursorFail cur dfltTy

readTyTagged : Int -> SexpCursor -> Ty
readTyTagged 0 cur =
  let a0 = readString cur
  let a1 = readOpt readLoc cur
  let a2 = readTyConOrigin cur
  TyCon { tyConName = a0, tyConLoc = a1, tyConOrigin = a2 }
readTyTagged 1 cur =
  let a0 = readString cur
  TyVar a0
readTyTagged 2 cur =
  let a0 = readTy cur
  let a1 = readTy cur
  TyApp a0 a1
readTyTagged 3 cur =
  let a0 = readTy cur
  let a1 = readTy cur
  TyFun a0 a1
readTyTagged 4 cur =
  let a0 = cursorList readTy cur
  TyTuple a0
readTyTagged 5 cur =
  let a0 = cursorList readEffAtomTy cur
  let a1 = cursorList readString cur
  let a2 = readTy cur
  TyEffect a0 a1 a2
readTyTagged 6 cur =
  let a0 = cursorList readConstraint cur
  let a1 = readTy cur
  TyConstrained a0 a1
readTyTagged 7 cur =
  let a0 = readString cur
  let a1 = readTy cur
  let a2 = readOpt readEffAtomTy cur
  TyNamed a0 a1 a2
readTyTagged 8 cur =
  let a0 = readTy cur
  let a1 = cursorList readEffParamTy cur
  let a2 = readOpt readLoc cur
  TyQual a0 a1 a2
readTyTagged 9 cur =
  let a0 = cursorList readEffAtomTy cur
  let a1 = cursorList readString cur
  let a2 = readOpt readLoc cur
  TyRow a0 a1 a2
readTyTagged 10 cur =
  let a0 = cursorList readEffParamTy cur
  let a1 = readOpt readLoc cur
  TyAuth a0 a1
readTyTagged _ cur = cursorFail cur dfltTy

readEffAtomTy : SexpCursor -> EffAtomTy
readEffAtomTy cur =
  let _ = cursorOpen cur
  let a0 = readString cur
  let a1 = readTyConOrigin cur
  let a2 = readEffParamTy cur
  let a3 = readOpt readLoc cur
  let a4 = readBool cur
  let _ = cursorClose cur
  EffAtomTy {
    eatLabel = a0,
    eatOrigin = a1,
    eatParam = a2,
    eatLoc = a3,
    eatPattern = a4,
  }

readEffParamTy : SexpCursor -> EffParamTy
readEffParamTy cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let v = readEffParamTyTagged (cursorInt cur) cur
    let _ = cursorClose cur
    v
  else
    readEffParamTyBare (cursorInt cur) cur

readEffParamTyBare : Int -> SexpCursor -> EffParamTy
readEffParamTyBare 0 _ = EPTop
readEffParamTyBare _ cur = cursorFail cur dfltEffParamTy

readEffParamTyTagged : Int -> SexpCursor -> EffParamTy
readEffParamTyTagged 1 cur =
  let a0 = readString cur
  EPLit a0
readEffParamTyTagged 2 cur =
  let a0 = readString cur
  EPName a0
readEffParamTyTagged 3 cur =
  let a0 = cursorList readString cur
  EPSet a0
readEffParamTyTagged 4 cur =
  let a0 = cursorList (readPair readString readEffParamTy) cur
  EPProduct a0
readEffParamTyTagged _ cur = cursorFail cur dfltEffParamTy

readConstraint : SexpCursor -> Constraint
readConstraint cur =
  let _ = cursorOpen cur
  let a0 = readString cur
  let a1 = cursorList readTy cur
  let a2 = readTyConOrigin cur
  let _ = cursorClose cur
  Constraint { constraintHead = a0, constraintArgs = a1, constraintOrigin = a2 }

readKindAnn : SexpCursor -> KindAnn
readKindAnn cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let v = readKindAnnTagged (cursorInt cur) cur
    let _ = cursorClose cur
    v
  else
    readKindAnnBare (cursorInt cur) cur

readKindAnnBare : Int -> SexpCursor -> KindAnn
readKindAnnBare 0 _ = KindType
readKindAnnBare 1 _ = KindEffect
readKindAnnBare _ cur = cursorFail cur dfltKindAnn

readKindAnnTagged : Int -> SexpCursor -> KindAnn
readKindAnnTagged 2 cur =
  let a0 = readString cur
  let a1 = readTyConOrigin cur
  let a2 = readBool cur
  let a3 = readOpt readLoc cur
  KindAuthority a0 a1 a2 a3
readKindAnnTagged 3 cur =
  let a0 = readKindAnn cur
  let a1 = readKindAnn cur
  KindArrow a0 a1
readKindAnnTagged _ cur = cursorFail cur dfltKindAnn

readRoute : SexpCursor -> Route
readRoute cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let v = readRouteTagged (cursorInt cur) cur
    let _ = cursorClose cur
    v
  else
    readRouteBare (cursorInt cur) cur

readRouteBare : Int -> SexpCursor -> Route
readRouteBare 0 _ = RNone
readRouteBare _ cur = cursorFail cur dfltRoute

readRouteTagged : Int -> SexpCursor -> Route
readRouteTagged 1 cur =
  let a0 = readString cur
  let a1 = cursorList readRoute cur
  let a2 = cursorList readRoute cur
  RKey a0 a1 a2
readRouteTagged 2 cur =
  let a0 = readString cur
  RDict a0
readRouteTagged 3 cur =
  let a0 = readString cur
  RDictFwd a0
readRouteTagged 4 cur =
  let a0 = readString cur
  let a1 = cursorList readRoute cur
  RLocal a0 a1
readRouteTagged 5 cur =
  let a0 = readString cur
  RScalar a0
readRouteTagged 6 cur =
  let a0 = readRoute cur
  let a1 = cursorList readInt cur
  RProj a0 a1
readRouteTagged _ cur = cursorFail cur dfltRoute

readEvVal : SexpCursor -> EvVal
readEvVal cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let v = readEvValTagged (cursorInt cur) cur
    let _ = cursorClose cur
    v
  else
    readEvValBare (cursorInt cur) cur

readEvValBare : Int -> SexpCursor -> EvVal
readEvValBare _ cur = cursorFail cur dfltEvVal

readEvValTagged : Int -> SexpCursor -> EvVal
readEvValTagged 0 cur =
  let a0 = readRoute cur
  EvOne a0
readEvValTagged 1 cur =
  let a0 = cursorList readRoute cur
  EvMany a0
readEvValTagged 2 cur =
  let a0 = readString cur
  let a1 = readInt cur
  let a2 = readRoute cur
  let a3 = cursorList readRoute cur
  let a4 = cursorList readRoute cur
  EvMethod a0 a1 a2 a3 a4
readEvValTagged 3 cur =
  let a0 = readOpt readFloat cur
  let a1 = readRoute cur
  EvLit a0 a1
readEvValTagged 4 cur =
  let a0 = readString cur
  EvHead a0
readEvValTagged _ cur = cursorFail cur dfltEvVal

readEvEntry : SexpCursor -> EvEntry
readEvEntry cur =
  let _ = cursorOpen cur
  let a0 = readEvId cur
  let a1 = readEvVal cur
  let _ = cursorClose cur
  EvEntry a0 a1

readAddr : SexpCursor -> Addr
readAddr cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let v = readAddrTagged (cursorInt cur) cur
    let _ = cursorClose cur
    v
  else
    readAddrBare (cursorInt cur) cur

readAddrBare : Int -> SexpCursor -> Addr
readAddrBare 1 _ = AGlobal
readAddrBare _ cur = cursorFail cur dfltAddr

readAddrTagged : Int -> SexpCursor -> Addr
readAddrTagged 0 cur =
  let a0 = readInt cur
  let a1 = readInt cur
  ALocal a0 a1
readAddrTagged _ cur = cursorFail cur dfltAddr

readPat : SexpCursor -> Pat
readPat cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let v = readPatTagged (cursorInt cur) cur
    let _ = cursorClose cur
    v
  else
    readPatBare (cursorInt cur) cur

readPatBare : Int -> SexpCursor -> Pat
readPatBare 1 _ = PWild
readPatBare _ cur = cursorFail cur dfltPat

readPatTagged : Int -> SexpCursor -> Pat
readPatTagged 0 cur =
  let a0 = readString cur
  let a1 = readLoc cur
  let a2 = readBinderId cur
  PVar a0 a1 a2
readPatTagged 2 cur =
  let a0 = readLit cur
  PLit a0
readPatTagged 3 cur =
  let a0 = readString cur
  let a1 = cursorList readPat cur
  PCon a0 a1
readPatTagged 4 cur =
  let a0 = readPat cur
  let a1 = readPat cur
  PCons a0 a1
readPatTagged 5 cur =
  let a0 = cursorList readPat cur
  PTuple a0
readPatTagged 6 cur =
  let a0 = cursorList readPat cur
  PList a0
readPatTagged 7 cur =
  let a0 = readString cur
  let a1 = readLoc cur
  let a2 = readBinderId cur
  let a3 = readPat cur
  PAs a0 a1 a2 a3
readPatTagged 8 cur =
  let a0 = readLit cur
  let a1 = readLit cur
  let a2 = readBool cur
  PRng a0 a1 a2
readPatTagged 9 cur =
  let a0 = readString cur
  let a1 = cursorList readRecPatField cur
  let a2 = readBool cur
  PRec a0 a1 a2
readPatTagged _ cur = cursorFail cur dfltPat

readRecPatField : SexpCursor -> RecPatField
readRecPatField cur =
  let _ = cursorOpen cur
  let a0 = readString cur
  let a1 = readLoc cur
  let a2 = readBinderId cur
  let a3 = readOpt readPat cur
  let _ = cursorClose cur
  RecPatField a0 a1 a2 a3

readGuard : SexpCursor -> Guard
readGuard cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let v = readGuardTagged (cursorInt cur) cur
    let _ = cursorClose cur
    v
  else
    readGuardBare (cursorInt cur) cur

readGuardBare : Int -> SexpCursor -> Guard
readGuardBare _ cur = cursorFail cur dfltGuard

readGuardTagged : Int -> SexpCursor -> Guard
readGuardTagged 0 cur =
  let a0 = readExpr cur
  GBool a0
readGuardTagged 1 cur =
  let a0 = readPat cur
  let a1 = readExpr cur
  GBind a0 a1
readGuardTagged _ cur = cursorFail cur dfltGuard

readArm : SexpCursor -> Arm
readArm cur =
  let _ = cursorOpen cur
  let a0 = readPat cur
  let a1 = cursorList readGuard cur
  let a2 = readExpr cur
  let _ = cursorClose cur
  Arm a0 a1 a2

readDoStmt : SexpCursor -> DoStmt
readDoStmt cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let v = readDoStmtTagged (cursorInt cur) cur
    let _ = cursorClose cur
    v
  else
    readDoStmtBare (cursorInt cur) cur

readDoStmtBare : Int -> SexpCursor -> DoStmt
readDoStmtBare _ cur = cursorFail cur dfltDoStmt

readDoStmtTagged : Int -> SexpCursor -> DoStmt
readDoStmtTagged 0 cur =
  let a0 = readExpr cur
  DoExpr a0
readDoStmtTagged 1 cur =
  let a0 = readPat cur
  let a1 = readExpr cur
  DoBind a0 a1
readDoStmtTagged 2 cur =
  let a0 = readBool cur
  let a1 = readBool cur
  let a2 = readPat cur
  let a3 = readExpr cur
  let a4 = readLoc cur
  DoLet a0 a1 a2 a3 a4
readDoStmtTagged 3 cur =
  let a0 = readString cur
  let a1 = readExpr cur
  DoAssign a0 a1
readDoStmtTagged 4 cur =
  let a0 = readString cur
  let a1 = cursorList readString cur
  let a2 = readExpr cur
  DoFieldAssign a0 a1 a2
readDoStmtTagged _ cur = cursorFail cur dfltDoStmt

readInterpPart : SexpCursor -> InterpPart
readInterpPart cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let v = readInterpPartTagged (cursorInt cur) cur
    let _ = cursorClose cur
    v
  else
    readInterpPartBare (cursorInt cur) cur

readInterpPartBare : Int -> SexpCursor -> InterpPart
readInterpPartBare _ cur = cursorFail cur dfltInterpPart

readInterpPartTagged : Int -> SexpCursor -> InterpPart
readInterpPartTagged 0 cur =
  let a0 = readString cur
  InterpStr a0
readInterpPartTagged 1 cur =
  let a0 = readExpr cur
  InterpExpr a0
readInterpPartTagged _ cur = cursorFail cur dfltInterpPart

readGuardArm : SexpCursor -> GuardArm
readGuardArm cur =
  let _ = cursorOpen cur
  let a0 = cursorList readGuard cur
  let a1 = readExpr cur
  let _ = cursorClose cur
  GuardArm a0 a1

readFieldAssign : SexpCursor -> FieldAssign
readFieldAssign cur =
  let _ = cursorOpen cur
  let a0 = readString cur
  let a1 = readExpr cur
  let _ = cursorClose cur
  FieldAssign a0 a1

readSection : SexpCursor -> Section
readSection cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let v = readSectionTagged (cursorInt cur) cur
    let _ = cursorClose cur
    v
  else
    readSectionBare (cursorInt cur) cur

readSectionBare : Int -> SexpCursor -> Section
readSectionBare _ cur = cursorFail cur dfltSection

readSectionTagged : Int -> SexpCursor -> Section
readSectionTagged 0 cur =
  let a0 = readString cur
  SecBare a0
readSectionTagged 1 cur =
  let a0 = readString cur
  let a1 = readExpr cur
  SecRight a0 a1
readSectionTagged 2 cur =
  let a0 = readExpr cur
  let a1 = readString cur
  SecLeft a0 a1
readSectionTagged _ cur = cursorFail cur dfltSection

readFunClause : SexpCursor -> FunClause
readFunClause cur =
  let _ = cursorOpen cur
  let a0 = cursorList readPat cur
  let a1 = readExpr cur
  let _ = cursorClose cur
  FunClause a0 a1

readLetBind : SexpCursor -> LetBind
readLetBind cur =
  let _ = cursorOpen cur
  let a0 = readString cur
  let a1 = cursorList readFunClause cur
  let a2 = readLoc cur
  let a3 = readBinderId cur
  let _ = cursorClose cur
  LetBind a0 a1 a2 a3

readExpr : SexpCursor -> Expr
readExpr cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let v = readExprTagged (cursorInt cur) cur
    let _ = cursorClose cur
    v
  else
    readExprBare (cursorInt cur) cur

readExprBare : Int -> SexpCursor -> Expr
readExprBare _ cur = cursorFail cur dfltExpr

readExprTagged : Int -> SexpCursor -> Expr
readExprTagged 0 cur =
  let a0 = readLit cur
  ELit a0
readExprTagged 1 cur =
  let a0 = readString cur
  EVar a0
readExprTagged 2 cur =
  let a0 = readExpr cur
  let a1 = readExpr cur
  EApp a0 a1
readExprTagged 3 cur =
  let a0 = cursorList readPat cur
  let a1 = readExpr cur
  ELam a0 a1
readExprTagged 4 cur =
  let a0 = readLoc cur
  let a1 = readBool cur
  let a2 = readPat cur
  let a3 = readExpr cur
  let a4 = readExpr cur
  ELet a0 a1 a2 a3 a4
readExprTagged 5 cur =
  let a0 = readExpr cur
  let a1 = cursorList readArm cur
  EMatch a0 a1
readExprTagged 6 cur =
  let a0 = readExpr cur
  let a1 = readExpr cur
  let a2 = readExpr cur
  EIf a0 a1 a2
readExprTagged 7 cur =
  let a0 = readString cur
  let a1 = readExpr cur
  let a2 = readExpr cur
  let a3 = readEvId cur
  EBinOp a0 a1 a2 a3
readExprTagged 8 cur =
  let a0 = readString cur
  let a1 = readExpr cur
  let a2 = readEvId cur
  EUnOp a0 a1 a2
readExprTagged 9 cur =
  let a0 = readString cur
  let a1 = readExpr cur
  let a2 = readExpr cur
  EInfix a0 a1 a2
readExprTagged 10 cur =
  let a0 = readExpr cur
  let a1 = readString cur
  let a2 = readEvId cur
  EFieldAccess a0 a1 a2
readExprTagged 11 cur =
  let a0 = cursorList readExpr cur
  ETuple a0
readExprTagged 12 cur =
  let a0 = cursorList readExpr cur
  EListLit a0
readExprTagged 13 cur =
  let a0 = cursorList readExpr cur
  EArrayLit a0
readExprTagged 14 cur =
  let a0 = readExpr cur
  let a1 = readExpr cur
  let a2 = readBool cur
  ERangeList a0 a1 a2
readExprTagged 15 cur =
  let a0 = readExpr cur
  let a1 = readExpr cur
  let a2 = readBool cur
  ERangeArray a0 a1 a2
readExprTagged 16 cur =
  let a0 = readExpr cur
  let a1 = readExpr cur
  let a2 = readExpr cur
  let a3 = readBool cur
  ESlice a0 a1 a2 a3
readExprTagged 17 cur =
  let a0 = cursorList readLetBind cur
  let a1 = readExpr cur
  ELetGroup a0 a1
readExprTagged 18 cur =
  let a0 = readSection cur
  ESection a0
readExprTagged 19 cur =
  let a0 = readExpr cur
  let a1 = readExpr cur
  EIndex a0 a1
readExprTagged 20 cur =
  let a0 = readExpr cur
  let a1 = readTy cur
  EAnnot a0 a1
readExprTagged 21 cur =
  let a0 = readExpr cur
  let a1 = readTy cur
  EHeadAnnot a0 a1
readExprTagged 22 cur =
  let a0 = cursorList readDoStmt cur
  EBlock a0
readExprTagged 23 cur =
  let a0 = readBool cur
  let a1 = cursorList readDoStmt cur
  EDo a0 a1
readExprTagged 24 cur =
  let a0 = cursorList readInterpPart cur
  EStringInterp a0
readExprTagged 25 cur =
  let a0 = cursorList readGuardArm cur
  EGuards a0
readExprTagged 26 cur =
  let a0 = readString cur
  let a1 = cursorList readFieldAssign cur
  ERecordCreate a0 a1
readExprTagged 27 cur =
  let a0 = readExpr cur
  let a1 = cursorList readFieldAssign cur
  let a2 = readEvId cur
  ERecordUpdate a0 a1 a2
readExprTagged 28 cur =
  let a0 = readString cur
  let a1 = readExpr cur
  let a2 = cursorList readFieldAssign cur
  EVariantUpdate a0 a1 a2
readExprTagged 29 cur =
  let a0 = readString cur
  let a1 = cursorList (readPair readExpr readExpr) cur
  EMapLit a0 a1
readExprTagged 30 cur =
  let a0 = readString cur
  let a1 = cursorList readExpr cur
  ESetLit a0 a1
readExprTagged 31 cur =
  let a0 = readString cur
  let a1 = readExpr cur
  EAsPat a0 a1
readExprTagged 32 cur =
  let a0 = readString cur
  EMethodRef a0
readExprTagged 33 cur =
  let a0 = readString cur
  EDictApp a0
readExprTagged 34 cur =
  let a0 = readString cur
  let a1 = readAddr cur
  EVarAt a0 a1
readExprTagged 35 cur =
  let a0 = readString cur
  let a1 = readInt cur
  EVarId a0 a1
readExprTagged 36 cur =
  let a0 = readString cur
  let a1 = readString cur
  let a2 = readEvId cur
  EMethodAt a0 a1 a2
readExprTagged 37 cur =
  let a0 = readString cur
  let a1 = readEvId cur
  EDictAt a0 a1
readExprTagged 38 cur =
  let a0 = readLoc cur
  let a1 = readExpr cur
  ELoc a0 a1
readExprTagged 39 cur =
  let a0 = readLoc cur
  let a1 = readExpr cur
  EDoOrigin a0 a1
readExprTagged 40 cur =
  let a0 = readInt cur
  let a1 = readEvId cur
  let a2 = readString cur
  ENumLit a0 a1 a2
readExprTagged 41 cur =
  let a0 = readInt cur
  let a1 = readInt cur
  let a2 = readEvId cur
  let a3 = readString cur
  EWideLit a0 a1 a2 a3
readExprTagged _ cur = cursorFail cur dfltExpr

readUseMember : SexpCursor -> UseMember
readUseMember cur =
  let _ = cursorOpen cur
  let a0 = readString cur
  let a1 = readBool cur
  let a2 = readLoc cur
  let a3 = readOpt readString cur
  let _ = cursorClose cur
  UseMember a0 a1 a2 a3

readUsePath : SexpCursor -> UsePath
readUsePath cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let v = readUsePathTagged (cursorInt cur) cur
    let _ = cursorClose cur
    v
  else
    readUsePathBare (cursorInt cur) cur

readUsePathBare : Int -> SexpCursor -> UsePath
readUsePathBare _ cur = cursorFail cur dfltUsePath

readUsePathTagged : Int -> SexpCursor -> UsePath
readUsePathTagged 0 cur =
  let a0 = cursorList readString cur
  UseName a0
readUsePathTagged 1 cur =
  let a0 = cursorList readString cur
  let a1 = cursorList readUseMember cur
  UseGroup a0 a1
readUsePathTagged 2 cur =
  let a0 = cursorList readString cur
  UseWild a0
readUsePathTagged 3 cur =
  let a0 = cursorList readString cur
  let a1 = readString cur
  UseAlias a0 a1
readUsePathTagged _ cur = cursorFail cur dfltUsePath

readPropParam : SexpCursor -> PropParam
readPropParam cur =
  let _ = cursorOpen cur
  let a0 = readString cur
  let a1 = readLoc cur
  let a2 = readTy cur
  let _ = cursorClose cur
  PropParam a0 a1 a2

readMethodDefault : SexpCursor -> MethodDefault
readMethodDefault cur =
  let _ = cursorOpen cur
  let a0 = cursorList readPat cur
  let a1 = readExpr cur
  let _ = cursorClose cur
  MethodDefault a0 a1

readIfaceMethod : SexpCursor -> IfaceMethod
readIfaceMethod cur =
  let _ = cursorOpen cur
  let a0 = readString cur
  let a1 = readTy cur
  let a2 = readOpt readMethodDefault cur
  let a3 = readOpt readLoc cur
  let _ = cursorClose cur
  IfaceMethod a0 a1 a2 a3

readSuper : SexpCursor -> Super
readSuper cur =
  let _ = cursorOpen cur
  let a0 = readString cur
  let a1 = cursorList readString cur
  let a2 = readTyConOrigin cur
  let _ = cursorClose cur
  Super { superHead = a0, superParams = a1, superOrigin = a2 }

readRequire : SexpCursor -> Require
readRequire cur =
  let _ = cursorOpen cur
  let a0 = readString cur
  let a1 = cursorList readTy cur
  let a2 = readTyConOrigin cur
  let _ = cursorClose cur
  Require { requireHead = a0, requireArgs = a1, requireOrigin = a2 }

readImplMethod : SexpCursor -> ImplMethod
readImplMethod cur =
  let _ = cursorOpen cur
  let a0 = readString cur
  let a1 = cursorList readPat cur
  let a2 = readExpr cur
  let _ = cursorClose cur
  ImplMethod a0 a1 a2

readDataVis : SexpCursor -> DataVis
readDataVis cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let v = readDataVisTagged (cursorInt cur) cur
    let _ = cursorClose cur
    v
  else
    readDataVisBare (cursorInt cur) cur

readDataVisBare : Int -> SexpCursor -> DataVis
readDataVisBare 0 _ = VisPrivate
readDataVisBare 1 _ = VisAbstract
readDataVisBare 2 _ = VisPublic
readDataVisBare _ cur = cursorFail cur dfltDataVis

readDataVisTagged : Int -> SexpCursor -> DataVis
readDataVisTagged _ cur = cursorFail cur dfltDataVis

readField : SexpCursor -> Field
readField cur =
  let _ = cursorOpen cur
  let a0 = readString cur
  let a1 = readTy cur
  let _ = cursorClose cur
  Field a0 a1

readConPayload : SexpCursor -> ConPayload
readConPayload cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let v = readConPayloadTagged (cursorInt cur) cur
    let _ = cursorClose cur
    v
  else
    readConPayloadBare (cursorInt cur) cur

readConPayloadBare : Int -> SexpCursor -> ConPayload
readConPayloadBare _ cur = cursorFail cur dfltConPayload

readConPayloadTagged : Int -> SexpCursor -> ConPayload
readConPayloadTagged 0 cur =
  let a0 = cursorList readTy cur
  ConPos a0
readConPayloadTagged 1 cur =
  let a0 = cursorList readField cur
  let a1 = readBool cur
  ConNamed a0 a1
readConPayloadTagged _ cur = cursorFail cur dfltConPayload

readVariant : SexpCursor -> Variant
readVariant cur =
  let _ = cursorOpen cur
  let a0 = readString cur
  let a1 = readConPayload cur
  let _ = cursorClose cur
  Variant a0 a1

readAttr : SexpCursor -> Attr
readAttr cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let v = readAttrTagged (cursorInt cur) cur
    let _ = cursorClose cur
    v
  else
    readAttrBare (cursorInt cur) cur

readAttrBare : Int -> SexpCursor -> Attr
readAttrBare 1 _ = AttrInline
readAttrBare 2 _ = AttrMustUse
readAttrBare 3 _ = AttrNoInline
readAttrBare _ cur = cursorFail cur dfltAttr

readAttrTagged : Int -> SexpCursor -> Attr
readAttrTagged 0 cur =
  let a0 = readOpt readString cur
  AttrDeprecated a0
readAttrTagged _ cur = cursorFail cur dfltAttr

readDeriveRef : SexpCursor -> DeriveRef
readDeriveRef cur =
  let _ = cursorOpen cur
  let a0 = readString cur
  let a1 = readOpt readLoc cur
  let _ = cursorClose cur
  DeriveRef a0 a1

readExternDecl : SexpCursor -> ExternDecl
readExternDecl cur =
  let _ = cursorOpen cur
  let a0 = readBool cur
  let a1 = readString cur
  let a2 = readTy cur
  let a3 = readLoc cur
  let a4 = cursorList readExternBind cur
  let _ = cursorClose cur
  ExternDecl { edPub = a0, edName = a1, edTy = a2, edLoc = a3, edBinds = a4 }

readExternBind : SexpCursor -> ExternBind
readExternBind cur =
  let _ = cursorOpen cur
  let a0 = readString cur
  let a1 = readString cur
  let a2 = readLoc cur
  let _ = cursorClose cur
  ExternBind { ebHost = a0, ebSymbol = a1, ebLoc = a2 }

readDecl : SexpCursor -> Decl
readDecl cur =
  if cursorPeek cur == 40 then
    let _ = cursorAdvance cur
    let v = readDeclTagged (cursorInt cur) cur
    let _ = cursorClose cur
    v
  else
    readDeclBare (cursorInt cur) cur

readDeclBare : Int -> SexpCursor -> Decl
readDeclBare _ cur = cursorFail cur dfltDecl

readDeclTagged : Int -> SexpCursor -> Decl
readDeclTagged 0 cur =
  let a0 = readBool cur
  let a1 = readString cur
  let a2 = readTy cur
  let a3 = readLoc cur
  DTypeSig a0 a1 a2 a3
readDeclTagged 1 cur =
  let a0 = readExternDecl cur
  DExtern a0
readDeclTagged 2 cur =
  let a0 = readBool cur
  let a1 = readString cur
  let a2 = cursorList readPat cur
  let a3 = readExpr cur
  let a4 = readLoc cur
  let a5 = readBinderId cur
  DFunDef a0 a1 a2 a3 a4 a5
readDeclTagged 3 cur =
  let a0 = readDataVis cur
  let a1 = readString cur
  let a2 = cursorList readString cur
  let a3 = cursorList (readOpt readKindAnn) cur
  let a4 = cursorList readVariant cur
  let a5 = cursorList (cursorList (readPair readString readKindAnn)) cur
  let a6 = cursorList readDeriveRef cur
  let a7 = readTyConOrigin cur
  let a8 = readBool cur
  let a9 = readOpt readLoc cur
  DData {
    dataVis = a0,
    dataName = a1,
    dataParams = a2,
    dataParamKinds = a3,
    dataCtors = a4,
    dataCtorBinders = a5,
    dataDerives = a6,
    dataOrigin = a7,
    dataExtern = a8,
    dataNameLoc = a9,
  }
readDeclTagged 4 cur =
  let a0 = readBool cur
  let a1 = readUsePath cur
  let a2 = readLoc cur
  DUse a0 a1 a2
readDeclTagged 5 cur =
  let a0 = readBool cur
  let a1 = readString cur
  let a2 = readOpt readString cur
  let a3 = cursorList (readPair readString readString) cur
  let a4 = readTyConOrigin cur
  let a5 = readOpt readLoc cur
  DEffect a0 a1 a2 a3 a4 a5
readDeclTagged 6 cur =
  let a0 = readBool cur
  let a1 = readString cur
  let a2 = cursorList readPropParam cur
  let a3 = readExpr cur
  DProp a0 a1 a2 a3
readDeclTagged 7 cur =
  let a0 = readBool cur
  let a1 = readString cur
  let a2 = readExpr cur
  DTest a0 a1 a2
readDeclTagged 8 cur =
  let a0 = readBool cur
  let a1 = readBool cur
  let a2 = readString cur
  let a3 = cursorList readString cur
  let a4 = cursorList (readOpt readKindAnn) cur
  let a5 = cursorList readSuper cur
  let a6 = cursorList readIfaceMethod cur
  let a7 = readTyConOrigin cur
  let a8 = readOpt readLoc cur
  DInterface {
    pub = a0,
    def = a1,
    name = a2,
    typarams = a3,
    typaramKinds = a4,
    supers = a5,
    methods = a6,
    ifaceOrigin = a7,
    ifaceNameLoc = a8,
  }
readDeclTagged 9 cur =
  let a0 = readBool cur
  let a1 = readString cur
  let a2 = cursorList readTy cur
  let a3 = cursorList readRequire cur
  let a4 = cursorList readImplMethod cur
  let a5 = readTyConOrigin cur
  let a6 = readOpt readLoc cur
  DImpl {
    pub = a0,
    iface = a1,
    tys = a2,
    reqs = a3,
    methods = a4,
    implOrigin = a5,
    implIfaceLoc = a6,
  }
readDeclTagged 10 cur =
  let a0 = readBool cur
  let a1 = readString cur
  let a2 = cursorList readString cur
  let a3 = cursorList (readOpt readKindAnn) cur
  let a4 = readTy cur
  let a5 = readTyConOrigin cur
  let a6 = readOpt readLoc cur
  DTypeAlias {
    tyAliasPub = a0,
    tyAliasName = a1,
    tyAliasParams = a2,
    tyAliasParamKinds = a3,
    tyAliasRhs = a4,
    tyAliasOrigin = a5,
    tyAliasNameLoc = a6,
  }
readDeclTagged 11 cur =
  let a0 = readBool cur
  let a1 = readString cur
  let a2 = cursorList readString cur
  let a3 = cursorList (readOpt readKindAnn) cur
  let a4 = readString cur
  let a5 = cursorList (readPair readString readKindAnn) cur
  let a6 = readTy cur
  let a7 = cursorList readDeriveRef cur
  let a8 = readTyConOrigin cur
  let a9 = readOpt readLoc cur
  DNewtype {
    newtypePub = a0,
    newtypeName = a1,
    newtypeParams = a2,
    newtypeParamKinds = a3,
    newtypeCtor = a4,
    newtypeCtorBinders = a5,
    newtypeFieldTy = a6,
    newtypeDerives = a7,
    newtypeOrigin = a8,
    newtypeNameLoc = a9,
  }
readDeclTagged 12 cur =
  let a0 = readBool cur
  let a1 = cursorList readLetBind cur
  DLetGroup a0 a1
readDeclTagged 13 cur =
  let a0 = cursorList readAttr cur
  let a1 = readDecl cur
  DAttrib a0 a1
readDeclTagged _ cur = cursorFail cur dfltDecl
# DESUGAR
(DUse false (UseWild ("frontend" "ast")))
(DUse false (UseGroup ("array") ((mem "fromList" false))))
(DUse false (UseGroup ("list") ((mem "splitAt" false))))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "SexpCursor" false) (mem "SexpError" true) (mem "cursorAdvance" false) (mem "cursorAtEnd" false) (mem "cursorAtom" false) (mem "cursorClose" false) (mem "cursorFail" false) (mem "cursorFailed" false) (mem "cursorInt" false) (mem "cursorList" false) (mem "cursorOf" false) (mem "cursorOffset" false) (mem "cursorOpen" false) (mem "cursorPeek" false) (mem "cursorChar" false))))
(DTypeSig true "declsSExp" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "SExp")))
(DFunDef false "declsSExp" ((PVar "ds")) (EApp (EApp (EVar "sexpList") (EVar "sexpDecl")) (EVar "ds")))
(DTypeSig true "evEntriesSExp" (TyFun (TyApp (TyCon "List") (TyCon "EvEntry")) (TyCon "SExp")))
(DFunDef false "evEntriesSExp" ((PVar "es")) (EApp (EApp (EVar "sexpList") (EVar "sexpEvEntry")) (EVar "es")))
(DTypeSig true "readDecls" (TyFun (TyCon "SexpCursor") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "readDecls" ((PVar "cur")) (EApp (EApp (EApp (EVar "checked") (ELit (LString "decls"))) (EVar "cur")) (EApp (EApp (EVar "cursorList") (EVar "readDecl")) (EVar "cur"))))
(DTypeSig true "readEvEntries" (TyFun (TyCon "SexpCursor") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyApp (TyCon "List") (TyCon "EvEntry")))))
(DFunDef false "readEvEntries" ((PVar "cur")) (EApp (EApp (EApp (EVar "checked") (ELit (LString "evidence"))) (EVar "cur")) (EApp (EApp (EVar "cursorList") (EVar "readEvEntry")) (EVar "cur"))))
(DTypeSig true "decodeDecls" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "decodeDecls" ((PVar "text")) (EApp (EApp (EVar "decodeAll") (EVar "readDecls")) (EVar "text")))
(DTypeSig true "decodeEvEntries" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyApp (TyCon "List") (TyCon "EvEntry")))))
(DFunDef false "decodeEvEntries" ((PVar "text")) (EApp (EApp (EVar "decodeAll") (EVar "readEvEntries")) (EVar "text")))
(DTypeSig false "decodeAll" (TyFun (TyFun (TyCon "SexpCursor") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a"))) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))))
(DFunDef false "decodeAll" ((PVar "reader") (PVar "text")) (EBlock (DoLet false false (PVar "cur") (EApp (EVar "cursorOf") (EVar "text"))) (DoExpr (EMatch (EApp (EVar "reader") (EVar "cur")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "v")) () (EIf (EApp (EVar "cursorAtEnd") (EVar "cur")) (EApp (EVar "Ok") (EVar "v")) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (EApp (EVar "cursorOffset") (EVar "cur"))) (fa "sePath" (ELit (LString ""))) (fa "seWhat" (ELit (LString "trailing text after the encoded value"))))))))))))
(DTypeSig false "checked" (TyFun (TyCon "String") (TyFun (TyCon "SexpCursor") (TyFun (TyVar "a") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a"))))))
(DFunDef false "checked" ((PVar "path") (PVar "cur") (PVar "v")) (EIf (EApp (EVar "cursorFailed") (EVar "cur")) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (EApp (EVar "cursorOffset") (EVar "cur"))) (fa "sePath" (EVar "path")) (fa "seWhat" (ELit (LString "malformed or truncated encoding")))))) (EApp (EVar "Ok") (EVar "v"))))
(DTypeSig false "sexpInt" (TyFun (TyCon "Int") (TyCon "SExp")))
(DFunDef false "sexpInt" ((PVar "n")) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "n"))))
(DTypeSig false "sexpString" (TyFun (TyCon "String") (TyCon "SExp")))
(DFunDef false "sexpString" ((PVar "s")) (EApp (EVar "SAtom") (EVar "s")))
(DTypeSig true "sexpBool" (TyFun (TyCon "Bool") (TyCon "SExp")))
(DFunDef false "sexpBool" ((PVar "b")) (EApp (EVar "SAtom") (EIf (EVar "b") (ELit (LString "t")) (ELit (LString "f")))))
(DTypeSig false "sexpFloat" (TyFun (TyCon "Float") (TyCon "SExp")))
(DFunDef false "sexpFloat" ((PVar "f")) (EMatch (EApp (EApp (EVar "splitAt") (ELit (LInt 4))) (EApp (EVar "toList") (EApp (EVar "floatToBytes64") (EVar "f")))) (arm (PTuple (PVar "hi") (PVar "lo")) () (EApp (EVar "SList") (EListLit (EApp (EVar "sexpInt") (EApp (EVar "wordOf") (EVar "hi"))) (EApp (EVar "sexpInt") (EApp (EVar "wordOf") (EVar "lo"))))))))
(DTypeSig false "sexpList" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "SExp"))))
(DFunDef false "sexpList" ((PVar "f") (PVar "xs")) (EApp (EVar "SList") (EApp (EApp (EVar "map") (EVar "f")) (EVar "xs"))))
(DTypeSig false "sexpOpt" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyCon "SExp"))))
(DFunDef false "sexpOpt" (PWild (PCon "None")) (EApp (EVar "SList") (EListLit)))
(DFunDef false "sexpOpt" ((PVar "f") (PCon "Some" (PVar "x"))) (EApp (EVar "SList") (EListLit (EApp (EVar "f") (EVar "x")))))
(DTypeSig false "sexpPair" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyFun (TyVar "b") (TyCon "SExp")) (TyFun (TyTuple (TyVar "a") (TyVar "b")) (TyCon "SExp")))))
(DFunDef false "sexpPair" ((PVar "fa") (PVar "fb") (PTuple (PVar "a") (PVar "b"))) (EApp (EVar "SList") (EListLit (EApp (EVar "fa") (EVar "a")) (EApp (EVar "fb") (EVar "b")))))
(DTypeSig false "sexpLoc" (TyFun (TyCon "Loc") (TyCon "SExp")))
(DFunDef false "sexpLoc" ((PCon "Loc" (PLit (LString "")) (PLit (LInt 1)) (PLit (LInt 0)) (PLit (LInt 1)) (PLit (LInt 0)))) (EApp (EVar "SAtom") (ELit (LString "z"))))
(DFunDef false "sexpLoc" ((PCon "Loc" (PVar "f") (PVar "a") (PVar "b") (PVar "c") (PVar "d"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EVar "f")) (EApp (EVar "sexpInt") (EVar "a")) (EApp (EVar "sexpInt") (EVar "b")) (EApp (EVar "sexpInt") (EVar "c")) (EApp (EVar "sexpInt") (EVar "d")))))
(DTypeSig false "sexpEvId" (TyFun (TyCon "EvId") (TyCon "SExp")))
(DFunDef false "sexpEvId" ((PCon "EvId" (PLit (LString "")) (PVar "n"))) (EApp (EVar "sexpInt") (EVar "n")))
(DFunDef false "sexpEvId" ((PCon "EvId" (PVar "m") (PVar "n"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EVar "m")) (EApp (EVar "sexpInt") (EVar "n")))))
(DTypeSig true "sexpBinderId" (TyFun (TyCon "BinderId") (TyCon "SExp")))
(DFunDef false "sexpBinderId" ((PCon "BinderId" (PLit (LString "")) (PVar "n"))) (EApp (EVar "sexpInt") (EVar "n")))
(DFunDef false "sexpBinderId" ((PCon "BinderId" (PVar "m") (PVar "n"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EVar "m")) (EApp (EVar "sexpInt") (EVar "n")))))
(DTypeSig false "wordOf" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "wordOf" ((PVar "bytes")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "b")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 256))) (EVar "b")))) (ELit (LInt 0))) (EVar "bytes")))
(DTypeSig false "bytesOfWord" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "bytesOfWord" ((PVar "w")) (EListLit (EBinOp "%" (EBinOp "/" (EVar "w") (ELit (LInt 16777216))) (ELit (LInt 256))) (EBinOp "%" (EBinOp "/" (EVar "w") (ELit (LInt 65536))) (ELit (LInt 256))) (EBinOp "%" (EBinOp "/" (EVar "w") (ELit (LInt 256))) (ELit (LInt 256))) (EBinOp "%" (EVar "w") (ELit (LInt 256)))))
(DTypeSig false "readInt" (TyFun (TyCon "SexpCursor") (TyCon "Int")))
(DFunDef false "readInt" ((PVar "cur")) (EApp (EVar "cursorInt") (EVar "cur")))
(DTypeSig false "readString" (TyFun (TyCon "SexpCursor") (TyCon "String")))
(DFunDef false "readString" ((PVar "cur")) (EApp (EVar "cursorAtom") (EVar "cur")))
(DTypeSig true "readBool" (TyFun (TyCon "SexpCursor") (TyCon "Bool")))
(DFunDef false "readBool" ((PVar "cur")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "cursorChar") (EVar "cur"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LInt 116))) (EVar "True") (EIf (EBinOp "==" (EVar "c") (ELit (LInt 102))) (EVar "False") (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "False")))))))
(DTypeSig false "readFloat" (TyFun (TyCon "SexpCursor") (TyCon "Float")))
(DFunDef false "readFloat" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "hi") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "lo") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "hi") (ELit (LInt 0))) (EBinOp ">" (EVar "hi") (ELit (LInt 4294967295)))) (EBinOp "<" (EVar "lo") (ELit (LInt 0)))) (EBinOp ">" (EVar "lo") (ELit (LInt 4294967295)))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit (LFloat 0.0))) (EApp (EApp (EVar "bytesToFloat64") (EApp (EVar "fromList") (EBinOp "++" (EApp (EVar "bytesOfWord") (EVar "hi")) (EApp (EVar "bytesOfWord") (EVar "lo"))))) (ELit (LInt 0)))))))
(DTypeSig false "readOpt" (TyFun (TyFun (TyCon "SexpCursor") (TyVar "a")) (TyFun (TyCon "SexpCursor") (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "readOpt" ((PVar "f") (PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 41))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoExpr (EVar "None"))) (EBlock (DoLet false false (PVar "v") (EApp (EVar "f") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EVar "Some") (EVar "v"))))))))
(DTypeSig false "readPair" (TyFun (TyFun (TyCon "SexpCursor") (TyVar "a")) (TyFun (TyFun (TyCon "SexpCursor") (TyVar "b")) (TyFun (TyCon "SexpCursor") (TyTuple (TyVar "a") (TyVar "b"))))))
(DFunDef false "readPair" ((PVar "fa") (PVar "fb") (PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a") (EApp (EVar "fa") (EVar "cur"))) (DoLet false false (PVar "b") (EApp (EVar "fb") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ETuple (EVar "a") (EVar "b")))))
(DTypeSig false "readLoc" (TyFun (TyCon "SexpCursor") (TyCon "Loc")))
(DFunDef false "readLoc" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "f") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false (PVar "b") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false (PVar "c") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false (PVar "d") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "a")) (EVar "b")) (EVar "c")) (EVar "d")))) (EIf (EBinOp "==" (EApp (EVar "cursorChar") (EVar "cur")) (ELit (LInt 122))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 1))) (ELit (LInt 0))) (ELit (LInt 1))) (ELit (LInt 0))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltLoc")))))
(DTypeSig false "readEvId" (TyFun (TyCon "SexpCursor") (TyCon "EvId")))
(DFunDef false "readEvId" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "m") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "n") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EvId") (EVar "m")) (EVar "n")))) (EApp (EApp (EVar "EvId") (ELit (LString ""))) (EApp (EVar "readInt") (EVar "cur")))))
(DTypeSig true "readBinderId" (TyFun (TyCon "SexpCursor") (TyCon "BinderId")))
(DFunDef false "readBinderId" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "m") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "n") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "BinderId") (EVar "m")) (EVar "n")))) (EApp (EApp (EVar "BinderId") (ELit (LString ""))) (EApp (EVar "readInt") (EVar "cur")))))
(DTypeSig false "sexpLit" (TyFun (TyCon "Lit") (TyCon "SExp")))
(DFunDef false "sexpLit" ((PCon "LInt" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpInt") (EVar "a0")))))
(DFunDef false "sexpLit" ((PCon "LFloat" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "sexpFloat") (EVar "a0")))))
(DFunDef false "sexpLit" ((PCon "LU64" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpInt") (EVar "a0")) (EApp (EVar "sexpInt") (EVar "a1")))))
(DFunDef false "sexpLit" ((PCon "LI64" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EVar "sexpInt") (EVar "a0")) (EApp (EVar "sexpInt") (EVar "a1")))))
(DFunDef false "sexpLit" ((PCon "LString" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "4"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpLit" ((PCon "LChar" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "5"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpLit" ((PCon "LBool" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "6"))) (EApp (EVar "sexpBool") (EVar "a0")))))
(DFunDef false "sexpLit" ((PCon "LUnit")) (EApp (EVar "SAtom") (ELit (LString "7"))))
(DTypeSig false "sexpTyConOrigin" (TyFun (TyCon "TyConOrigin") (TyCon "SExp")))
(DFunDef false "sexpTyConOrigin" ((PCon "OriginUnresolved")) (EApp (EVar "SAtom") (ELit (LString "0"))))
(DFunDef false "sexpTyConOrigin" ((PCon "OriginBuiltin")) (EApp (EVar "SAtom") (ELit (LString "1"))))
(DFunDef false "sexpTyConOrigin" ((PCon "OriginModule" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DTypeSig false "sexpTy" (TyFun (TyCon "Ty") (TyCon "SExp")))
(DFunDef false "sexpTy" ((PRec "TyCon" ((rf "tyConName" (PVar "a0")) (rf "tyConLoc" (PVar "a1")) (rf "tyConOrigin" (PVar "a2"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a1")) (EApp (EVar "sexpTyConOrigin") (EVar "a2")))))
(DFunDef false "sexpTy" ((PCon "TyVar" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpTy" ((PCon "TyApp" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpTy") (EVar "a0")) (EApp (EVar "sexpTy") (EVar "a1")))))
(DFunDef false "sexpTy" ((PCon "TyFun" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EVar "sexpTy") (EVar "a0")) (EApp (EVar "sexpTy") (EVar "a1")))))
(DFunDef false "sexpTy" ((PCon "TyTuple" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "4"))) (EApp (EApp (EVar "sexpList") (EVar "sexpTy")) (EVar "a0")))))
(DFunDef false "sexpTy" ((PCon "TyEffect" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "5"))) (EApp (EApp (EVar "sexpList") (EVar "sexpEffAtomTy")) (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a1")) (EApp (EVar "sexpTy") (EVar "a2")))))
(DFunDef false "sexpTy" ((PCon "TyConstrained" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "6"))) (EApp (EApp (EVar "sexpList") (EVar "sexpConstraint")) (EVar "a0")) (EApp (EVar "sexpTy") (EVar "a1")))))
(DFunDef false "sexpTy" ((PCon "TyNamed" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "7"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpTy") (EVar "a1")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpEffAtomTy")) (EVar "a2")))))
(DFunDef false "sexpTy" ((PCon "TyQual" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "8"))) (EApp (EVar "sexpTy") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpEffParamTy")) (EVar "a1")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a2")))))
(DFunDef false "sexpTy" ((PCon "TyRow" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "9"))) (EApp (EApp (EVar "sexpList") (EVar "sexpEffAtomTy")) (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a1")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a2")))))
(DFunDef false "sexpTy" ((PCon "TyAuth" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "10"))) (EApp (EApp (EVar "sexpList") (EVar "sexpEffParamTy")) (EVar "a0")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a1")))))
(DTypeSig false "sexpEffAtomTy" (TyFun (TyCon "EffAtomTy") (TyCon "SExp")))
(DFunDef false "sexpEffAtomTy" ((PRec "EffAtomTy" ((rf "eatLabel" (PVar "a0")) (rf "eatOrigin" (PVar "a1")) (rf "eatParam" (PVar "a2")) (rf "eatLoc" (PVar "a3")) (rf "eatPattern" (PVar "a4"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpTyConOrigin") (EVar "a1")) (EApp (EVar "sexpEffParamTy") (EVar "a2")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a3")) (EApp (EVar "sexpBool") (EVar "a4")))))
(DTypeSig false "sexpEffParamTy" (TyFun (TyCon "EffParamTy") (TyCon "SExp")))
(DFunDef false "sexpEffParamTy" ((PCon "EPTop")) (EApp (EVar "SAtom") (ELit (LString "0"))))
(DFunDef false "sexpEffParamTy" ((PCon "EPLit" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpEffParamTy" ((PCon "EPName" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpEffParamTy" ((PCon "EPSet" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a0")))))
(DFunDef false "sexpEffParamTy" ((PCon "EPProduct" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "4"))) (EApp (EApp (EVar "sexpList") (EApp (EApp (EVar "sexpPair") (EVar "sexpString")) (EVar "sexpEffParamTy"))) (EVar "a0")))))
(DTypeSig false "sexpConstraint" (TyFun (TyCon "Constraint") (TyCon "SExp")))
(DFunDef false "sexpConstraint" ((PRec "Constraint" ((rf "constraintHead" (PVar "a0")) (rf "constraintArgs" (PVar "a1")) (rf "constraintOrigin" (PVar "a2"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpTy")) (EVar "a1")) (EApp (EVar "sexpTyConOrigin") (EVar "a2")))))
(DTypeSig false "sexpKindAnn" (TyFun (TyCon "KindAnn") (TyCon "SExp")))
(DFunDef false "sexpKindAnn" ((PCon "KindType")) (EApp (EVar "SAtom") (ELit (LString "0"))))
(DFunDef false "sexpKindAnn" ((PCon "KindEffect")) (EApp (EVar "SAtom") (ELit (LString "1"))))
(DFunDef false "sexpKindAnn" ((PCon "KindAuthority" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpTyConOrigin") (EVar "a1")) (EApp (EVar "sexpBool") (EVar "a2")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a3")))))
(DFunDef false "sexpKindAnn" ((PCon "KindArrow" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EVar "sexpKindAnn") (EVar "a0")) (EApp (EVar "sexpKindAnn") (EVar "a1")))))
(DTypeSig false "sexpRoute" (TyFun (TyCon "Route") (TyCon "SExp")))
(DFunDef false "sexpRoute" ((PCon "RNone")) (EApp (EVar "SAtom") (ELit (LString "0"))))
(DFunDef false "sexpRoute" ((PCon "RKey" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpRoute")) (EVar "a1")) (EApp (EApp (EVar "sexpList") (EVar "sexpRoute")) (EVar "a2")))))
(DFunDef false "sexpRoute" ((PCon "RDict" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpRoute" ((PCon "RDictFwd" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpRoute" ((PCon "RLocal" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "4"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpRoute")) (EVar "a1")))))
(DFunDef false "sexpRoute" ((PCon "RScalar" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "5"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpRoute" ((PCon "RProj" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "6"))) (EApp (EVar "sexpRoute") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpInt")) (EVar "a1")))))
(DTypeSig false "sexpEvVal" (TyFun (TyCon "EvVal") (TyCon "SExp")))
(DFunDef false "sexpEvVal" ((PCon "EvOne" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpRoute") (EVar "a0")))))
(DFunDef false "sexpEvVal" ((PCon "EvMany" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EApp (EVar "sexpList") (EVar "sexpRoute")) (EVar "a0")))))
(DFunDef false "sexpEvVal" ((PCon "EvMethod" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3") (PVar "a4"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpInt") (EVar "a1")) (EApp (EVar "sexpRoute") (EVar "a2")) (EApp (EApp (EVar "sexpList") (EVar "sexpRoute")) (EVar "a3")) (EApp (EApp (EVar "sexpList") (EVar "sexpRoute")) (EVar "a4")))))
(DFunDef false "sexpEvVal" ((PCon "EvLit" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EApp (EVar "sexpOpt") (EVar "sexpFloat")) (EVar "a0")) (EApp (EVar "sexpRoute") (EVar "a1")))))
(DFunDef false "sexpEvVal" ((PCon "EvHead" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "4"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DTypeSig false "sexpEvEntry" (TyFun (TyCon "EvEntry") (TyCon "SExp")))
(DFunDef false "sexpEvEntry" ((PCon "EvEntry" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpEvId") (EVar "a0")) (EApp (EVar "sexpEvVal") (EVar "a1")))))
(DTypeSig false "sexpAddr" (TyFun (TyCon "Addr") (TyCon "SExp")))
(DFunDef false "sexpAddr" ((PCon "ALocal" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpInt") (EVar "a0")) (EApp (EVar "sexpInt") (EVar "a1")))))
(DFunDef false "sexpAddr" ((PCon "AGlobal")) (EApp (EVar "SAtom") (ELit (LString "1"))))
(DTypeSig false "sexpPat" (TyFun (TyCon "Pat") (TyCon "SExp")))
(DFunDef false "sexpPat" ((PCon "PVar" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpLoc") (EVar "a1")) (EApp (EVar "sexpBinderId") (EVar "a2")))))
(DFunDef false "sexpPat" ((PCon "PWild")) (EApp (EVar "SAtom") (ELit (LString "1"))))
(DFunDef false "sexpPat" ((PCon "PLit" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpLit") (EVar "a0")))))
(DFunDef false "sexpPat" ((PCon "PCon" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpPat")) (EVar "a1")))))
(DFunDef false "sexpPat" ((PCon "PCons" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "4"))) (EApp (EVar "sexpPat") (EVar "a0")) (EApp (EVar "sexpPat") (EVar "a1")))))
(DFunDef false "sexpPat" ((PCon "PTuple" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "5"))) (EApp (EApp (EVar "sexpList") (EVar "sexpPat")) (EVar "a0")))))
(DFunDef false "sexpPat" ((PCon "PList" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "6"))) (EApp (EApp (EVar "sexpList") (EVar "sexpPat")) (EVar "a0")))))
(DFunDef false "sexpPat" ((PCon "PAs" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "7"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpLoc") (EVar "a1")) (EApp (EVar "sexpBinderId") (EVar "a2")) (EApp (EVar "sexpPat") (EVar "a3")))))
(DFunDef false "sexpPat" ((PCon "PRng" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "8"))) (EApp (EVar "sexpLit") (EVar "a0")) (EApp (EVar "sexpLit") (EVar "a1")) (EApp (EVar "sexpBool") (EVar "a2")))))
(DFunDef false "sexpPat" ((PCon "PRec" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "9"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpRecPatField")) (EVar "a1")) (EApp (EVar "sexpBool") (EVar "a2")))))
(DTypeSig false "sexpRecPatField" (TyFun (TyCon "RecPatField") (TyCon "SExp")))
(DFunDef false "sexpRecPatField" ((PCon "RecPatField" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpLoc") (EVar "a1")) (EApp (EVar "sexpBinderId") (EVar "a2")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpPat")) (EVar "a3")))))
(DTypeSig false "sexpGuard" (TyFun (TyCon "Guard") (TyCon "SExp")))
(DFunDef false "sexpGuard" ((PCon "GBool" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpExpr") (EVar "a0")))))
(DFunDef false "sexpGuard" ((PCon "GBind" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "sexpPat") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DTypeSig false "sexpArm" (TyFun (TyCon "Arm") (TyCon "SExp")))
(DFunDef false "sexpArm" ((PCon "Arm" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpPat") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpGuard")) (EVar "a1")) (EApp (EVar "sexpExpr") (EVar "a2")))))
(DTypeSig false "sexpDoStmt" (TyFun (TyCon "DoStmt") (TyCon "SExp")))
(DFunDef false "sexpDoStmt" ((PCon "DoExpr" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpExpr") (EVar "a0")))))
(DFunDef false "sexpDoStmt" ((PCon "DoBind" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "sexpPat") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DFunDef false "sexpDoStmt" ((PCon "DoLet" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3") (PVar "a4"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpBool") (EVar "a1")) (EApp (EVar "sexpPat") (EVar "a2")) (EApp (EVar "sexpExpr") (EVar "a3")) (EApp (EVar "sexpLoc") (EVar "a4")))))
(DFunDef false "sexpDoStmt" ((PCon "DoAssign" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DFunDef false "sexpDoStmt" ((PCon "DoFieldAssign" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "4"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a1")) (EApp (EVar "sexpExpr") (EVar "a2")))))
(DTypeSig false "sexpInterpPart" (TyFun (TyCon "InterpPart") (TyCon "SExp")))
(DFunDef false "sexpInterpPart" ((PCon "InterpStr" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpInterpPart" ((PCon "InterpExpr" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "sexpExpr") (EVar "a0")))))
(DTypeSig false "sexpGuardArm" (TyFun (TyCon "GuardArm") (TyCon "SExp")))
(DFunDef false "sexpGuardArm" ((PCon "GuardArm" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EApp (EVar "sexpList") (EVar "sexpGuard")) (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DTypeSig false "sexpFieldAssign" (TyFun (TyCon "FieldAssign") (TyCon "SExp")))
(DFunDef false "sexpFieldAssign" ((PCon "FieldAssign" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DTypeSig false "sexpSection" (TyFun (TyCon "Section") (TyCon "SExp")))
(DFunDef false "sexpSection" ((PCon "SecBare" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpSection" ((PCon "SecRight" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DFunDef false "sexpSection" ((PCon "SecLeft" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")))))
(DTypeSig false "sexpFunClause" (TyFun (TyCon "FunClause") (TyCon "SExp")))
(DFunDef false "sexpFunClause" ((PCon "FunClause" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EApp (EVar "sexpList") (EVar "sexpPat")) (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DTypeSig false "sexpLetBind" (TyFun (TyCon "LetBind") (TyCon "SExp")))
(DFunDef false "sexpLetBind" ((PCon "LetBind" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpFunClause")) (EVar "a1")) (EApp (EVar "sexpLoc") (EVar "a2")) (EApp (EVar "sexpBinderId") (EVar "a3")))))
(DTypeSig false "sexpExpr" (TyFun (TyCon "Expr") (TyCon "SExp")))
(DFunDef false "sexpExpr" ((PCon "ELit" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpLit") (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "EVar" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "EApp" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "ELam" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EApp (EVar "sexpList") (EVar "sexpPat")) (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "ELet" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3") (PVar "a4"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "4"))) (EApp (EVar "sexpLoc") (EVar "a0")) (EApp (EVar "sexpBool") (EVar "a1")) (EApp (EVar "sexpPat") (EVar "a2")) (EApp (EVar "sexpExpr") (EVar "a3")) (EApp (EVar "sexpExpr") (EVar "a4")))))
(DFunDef false "sexpExpr" ((PCon "EMatch" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "5"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpArm")) (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "EIf" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "6"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")) (EApp (EVar "sexpExpr") (EVar "a2")))))
(DFunDef false "sexpExpr" ((PCon "EBinOp" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "7"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")) (EApp (EVar "sexpExpr") (EVar "a2")) (EApp (EVar "sexpEvId") (EVar "a3")))))
(DFunDef false "sexpExpr" ((PCon "EUnOp" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "8"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")) (EApp (EVar "sexpEvId") (EVar "a2")))))
(DFunDef false "sexpExpr" ((PCon "EInfix" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "9"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")) (EApp (EVar "sexpExpr") (EVar "a2")))))
(DFunDef false "sexpExpr" ((PCon "EFieldAccess" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "10"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EVar "sexpEvId") (EVar "a2")))))
(DFunDef false "sexpExpr" ((PCon "ETuple" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "11"))) (EApp (EApp (EVar "sexpList") (EVar "sexpExpr")) (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "EListLit" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "12"))) (EApp (EApp (EVar "sexpList") (EVar "sexpExpr")) (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "EArrayLit" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "13"))) (EApp (EApp (EVar "sexpList") (EVar "sexpExpr")) (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "ERangeList" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "14"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")) (EApp (EVar "sexpBool") (EVar "a2")))))
(DFunDef false "sexpExpr" ((PCon "ERangeArray" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "15"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")) (EApp (EVar "sexpBool") (EVar "a2")))))
(DFunDef false "sexpExpr" ((PCon "ESlice" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "16"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")) (EApp (EVar "sexpExpr") (EVar "a2")) (EApp (EVar "sexpBool") (EVar "a3")))))
(DFunDef false "sexpExpr" ((PCon "ELetGroup" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "17"))) (EApp (EApp (EVar "sexpList") (EVar "sexpLetBind")) (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "ESection" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "18"))) (EApp (EVar "sexpSection") (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "EIndex" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "19"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "EAnnot" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "20"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EVar "sexpTy") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "EHeadAnnot" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "21"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EVar "sexpTy") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "EBlock" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "22"))) (EApp (EApp (EVar "sexpList") (EVar "sexpDoStmt")) (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "EDo" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "23"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpDoStmt")) (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "EStringInterp" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "24"))) (EApp (EApp (EVar "sexpList") (EVar "sexpInterpPart")) (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "EGuards" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "25"))) (EApp (EApp (EVar "sexpList") (EVar "sexpGuardArm")) (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "ERecordCreate" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "26"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpFieldAssign")) (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "ERecordUpdate" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "27"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpFieldAssign")) (EVar "a1")) (EApp (EVar "sexpEvId") (EVar "a2")))))
(DFunDef false "sexpExpr" ((PCon "EVariantUpdate" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "28"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")) (EApp (EApp (EVar "sexpList") (EVar "sexpFieldAssign")) (EVar "a2")))))
(DFunDef false "sexpExpr" ((PCon "EMapLit" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "29"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EApp (EApp (EVar "sexpPair") (EVar "sexpExpr")) (EVar "sexpExpr"))) (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "ESetLit" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "30"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpExpr")) (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "EAsPat" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "31"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "EMethodRef" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "32"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "EDictApp" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "33"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "EVarAt" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "34"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpAddr") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "EVarId" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "35"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpInt") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "EMethodAt" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "36"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EVar "sexpEvId") (EVar "a2")))))
(DFunDef false "sexpExpr" ((PCon "EDictAt" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "37"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpEvId") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "ELoc" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "38"))) (EApp (EVar "sexpLoc") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "EDoOrigin" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "39"))) (EApp (EVar "sexpLoc") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "ENumLit" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "40"))) (EApp (EVar "sexpInt") (EVar "a0")) (EApp (EVar "sexpEvId") (EVar "a1")) (EApp (EVar "sexpString") (EVar "a2")))))
(DFunDef false "sexpExpr" ((PCon "EWideLit" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "41"))) (EApp (EVar "sexpInt") (EVar "a0")) (EApp (EVar "sexpInt") (EVar "a1")) (EApp (EVar "sexpEvId") (EVar "a2")) (EApp (EVar "sexpString") (EVar "a3")))))
(DTypeSig false "sexpUseMember" (TyFun (TyCon "UseMember") (TyCon "SExp")))
(DFunDef false "sexpUseMember" ((PCon "UseMember" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpBool") (EVar "a1")) (EApp (EVar "sexpLoc") (EVar "a2")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpString")) (EVar "a3")))))
(DTypeSig false "sexpUsePath" (TyFun (TyCon "UsePath") (TyCon "SExp")))
(DFunDef false "sexpUsePath" ((PCon "UseName" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a0")))))
(DFunDef false "sexpUsePath" ((PCon "UseGroup" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpUseMember")) (EVar "a1")))))
(DFunDef false "sexpUsePath" ((PCon "UseWild" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a0")))))
(DFunDef false "sexpUsePath" ((PCon "UseAlias" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")))))
(DTypeSig false "sexpPropParam" (TyFun (TyCon "PropParam") (TyCon "SExp")))
(DFunDef false "sexpPropParam" ((PCon "PropParam" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpLoc") (EVar "a1")) (EApp (EVar "sexpTy") (EVar "a2")))))
(DTypeSig false "sexpMethodDefault" (TyFun (TyCon "MethodDefault") (TyCon "SExp")))
(DFunDef false "sexpMethodDefault" ((PCon "MethodDefault" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EApp (EVar "sexpList") (EVar "sexpPat")) (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DTypeSig false "sexpIfaceMethod" (TyFun (TyCon "IfaceMethod") (TyCon "SExp")))
(DFunDef false "sexpIfaceMethod" ((PCon "IfaceMethod" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpTy") (EVar "a1")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpMethodDefault")) (EVar "a2")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a3")))))
(DTypeSig false "sexpSuper" (TyFun (TyCon "Super") (TyCon "SExp")))
(DFunDef false "sexpSuper" ((PRec "Super" ((rf "superHead" (PVar "a0")) (rf "superParams" (PVar "a1")) (rf "superOrigin" (PVar "a2"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a1")) (EApp (EVar "sexpTyConOrigin") (EVar "a2")))))
(DTypeSig false "sexpRequire" (TyFun (TyCon "Require") (TyCon "SExp")))
(DFunDef false "sexpRequire" ((PRec "Require" ((rf "requireHead" (PVar "a0")) (rf "requireArgs" (PVar "a1")) (rf "requireOrigin" (PVar "a2"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpTy")) (EVar "a1")) (EApp (EVar "sexpTyConOrigin") (EVar "a2")))))
(DTypeSig false "sexpImplMethod" (TyFun (TyCon "ImplMethod") (TyCon "SExp")))
(DFunDef false "sexpImplMethod" ((PCon "ImplMethod" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpPat")) (EVar "a1")) (EApp (EVar "sexpExpr") (EVar "a2")))))
(DTypeSig false "sexpDataVis" (TyFun (TyCon "DataVis") (TyCon "SExp")))
(DFunDef false "sexpDataVis" ((PCon "VisPrivate")) (EApp (EVar "SAtom") (ELit (LString "0"))))
(DFunDef false "sexpDataVis" ((PCon "VisAbstract")) (EApp (EVar "SAtom") (ELit (LString "1"))))
(DFunDef false "sexpDataVis" ((PCon "VisPublic")) (EApp (EVar "SAtom") (ELit (LString "2"))))
(DTypeSig false "sexpField" (TyFun (TyCon "Field") (TyCon "SExp")))
(DFunDef false "sexpField" ((PCon "Field" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpTy") (EVar "a1")))))
(DTypeSig false "sexpConPayload" (TyFun (TyCon "ConPayload") (TyCon "SExp")))
(DFunDef false "sexpConPayload" ((PCon "ConPos" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EApp (EVar "sexpList") (EVar "sexpTy")) (EVar "a0")))))
(DFunDef false "sexpConPayload" ((PCon "ConNamed" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EApp (EVar "sexpList") (EVar "sexpField")) (EVar "a0")) (EApp (EVar "sexpBool") (EVar "a1")))))
(DTypeSig false "sexpVariant" (TyFun (TyCon "Variant") (TyCon "SExp")))
(DFunDef false "sexpVariant" ((PCon "Variant" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpConPayload") (EVar "a1")))))
(DTypeSig false "sexpAttr" (TyFun (TyCon "Attr") (TyCon "SExp")))
(DFunDef false "sexpAttr" ((PCon "AttrDeprecated" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EApp (EVar "sexpOpt") (EVar "sexpString")) (EVar "a0")))))
(DFunDef false "sexpAttr" ((PCon "AttrInline")) (EApp (EVar "SAtom") (ELit (LString "1"))))
(DFunDef false "sexpAttr" ((PCon "AttrMustUse")) (EApp (EVar "SAtom") (ELit (LString "2"))))
(DFunDef false "sexpAttr" ((PCon "AttrNoInline")) (EApp (EVar "SAtom") (ELit (LString "3"))))
(DTypeSig false "sexpDeriveRef" (TyFun (TyCon "DeriveRef") (TyCon "SExp")))
(DFunDef false "sexpDeriveRef" ((PCon "DeriveRef" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a1")))))
(DTypeSig false "sexpExternDecl" (TyFun (TyCon "ExternDecl") (TyCon "SExp")))
(DFunDef false "sexpExternDecl" ((PRec "ExternDecl" ((rf "edPub" (PVar "a0")) (rf "edName" (PVar "a1")) (rf "edTy" (PVar "a2")) (rf "edLoc" (PVar "a3")) (rf "edBinds" (PVar "a4"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EVar "sexpTy") (EVar "a2")) (EApp (EVar "sexpLoc") (EVar "a3")) (EApp (EApp (EVar "sexpList") (EVar "sexpExternBind")) (EVar "a4")))))
(DTypeSig false "sexpExternBind" (TyFun (TyCon "ExternBind") (TyCon "SExp")))
(DFunDef false "sexpExternBind" ((PRec "ExternBind" ((rf "ebHost" (PVar "a0")) (rf "ebSymbol" (PVar "a1")) (rf "ebLoc" (PVar "a2"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EVar "sexpLoc") (EVar "a2")))))
(DTypeSig false "sexpDecl" (TyFun (TyCon "Decl") (TyCon "SExp")))
(DFunDef false "sexpDecl" ((PCon "DTypeSig" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EVar "sexpTy") (EVar "a2")) (EApp (EVar "sexpLoc") (EVar "a3")))))
(DFunDef false "sexpDecl" ((PCon "DExtern" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "sexpExternDecl") (EVar "a0")))))
(DFunDef false "sexpDecl" ((PCon "DFunDef" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3") (PVar "a4") (PVar "a5"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EApp (EVar "sexpList") (EVar "sexpPat")) (EVar "a2")) (EApp (EVar "sexpExpr") (EVar "a3")) (EApp (EVar "sexpLoc") (EVar "a4")) (EApp (EVar "sexpBinderId") (EVar "a5")))))
(DFunDef false "sexpDecl" ((PRec "DData" ((rf "dataVis" (PVar "a0")) (rf "dataName" (PVar "a1")) (rf "dataParams" (PVar "a2")) (rf "dataParamKinds" (PVar "a3")) (rf "dataCtors" (PVar "a4")) (rf "dataCtorBinders" (PVar "a5")) (rf "dataDerives" (PVar "a6")) (rf "dataOrigin" (PVar "a7")) (rf "dataExtern" (PVar "a8")) (rf "dataNameLoc" (PVar "a9"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EVar "sexpDataVis") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a2")) (EApp (EApp (EVar "sexpList") (EApp (EVar "sexpOpt") (EVar "sexpKindAnn"))) (EVar "a3")) (EApp (EApp (EVar "sexpList") (EVar "sexpVariant")) (EVar "a4")) (EApp (EApp (EVar "sexpList") (EApp (EVar "sexpList") (EApp (EApp (EVar "sexpPair") (EVar "sexpString")) (EVar "sexpKindAnn")))) (EVar "a5")) (EApp (EApp (EVar "sexpList") (EVar "sexpDeriveRef")) (EVar "a6")) (EApp (EVar "sexpTyConOrigin") (EVar "a7")) (EApp (EVar "sexpBool") (EVar "a8")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a9")))))
(DFunDef false "sexpDecl" ((PCon "DUse" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "4"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpUsePath") (EVar "a1")) (EApp (EVar "sexpLoc") (EVar "a2")))))
(DFunDef false "sexpDecl" ((PCon "DEffect" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3") (PVar "a4") (PVar "a5"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "5"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpString")) (EVar "a2")) (EApp (EApp (EVar "sexpList") (EApp (EApp (EVar "sexpPair") (EVar "sexpString")) (EVar "sexpString"))) (EVar "a3")) (EApp (EVar "sexpTyConOrigin") (EVar "a4")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a5")))))
(DFunDef false "sexpDecl" ((PCon "DProp" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "6"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EApp (EVar "sexpList") (EVar "sexpPropParam")) (EVar "a2")) (EApp (EVar "sexpExpr") (EVar "a3")))))
(DFunDef false "sexpDecl" ((PCon "DTest" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "7"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EVar "sexpExpr") (EVar "a2")))))
(DFunDef false "sexpDecl" ((PRec "DInterface" ((rf "pub" (PVar "a0")) (rf "def" (PVar "a1")) (rf "name" (PVar "a2")) (rf "typarams" (PVar "a3")) (rf "typaramKinds" (PVar "a4")) (rf "supers" (PVar "a5")) (rf "methods" (PVar "a6")) (rf "ifaceOrigin" (PVar "a7")) (rf "ifaceNameLoc" (PVar "a8"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "8"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpBool") (EVar "a1")) (EApp (EVar "sexpString") (EVar "a2")) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a3")) (EApp (EApp (EVar "sexpList") (EApp (EVar "sexpOpt") (EVar "sexpKindAnn"))) (EVar "a4")) (EApp (EApp (EVar "sexpList") (EVar "sexpSuper")) (EVar "a5")) (EApp (EApp (EVar "sexpList") (EVar "sexpIfaceMethod")) (EVar "a6")) (EApp (EVar "sexpTyConOrigin") (EVar "a7")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a8")))))
(DFunDef false "sexpDecl" ((PRec "DImpl" ((rf "pub" (PVar "a0")) (rf "iface" (PVar "a1")) (rf "tys" (PVar "a2")) (rf "reqs" (PVar "a3")) (rf "methods" (PVar "a4")) (rf "implOrigin" (PVar "a5")) (rf "implIfaceLoc" (PVar "a6"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "9"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EApp (EVar "sexpList") (EVar "sexpTy")) (EVar "a2")) (EApp (EApp (EVar "sexpList") (EVar "sexpRequire")) (EVar "a3")) (EApp (EApp (EVar "sexpList") (EVar "sexpImplMethod")) (EVar "a4")) (EApp (EVar "sexpTyConOrigin") (EVar "a5")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a6")))))
(DFunDef false "sexpDecl" ((PRec "DTypeAlias" ((rf "tyAliasPub" (PVar "a0")) (rf "tyAliasName" (PVar "a1")) (rf "tyAliasParams" (PVar "a2")) (rf "tyAliasParamKinds" (PVar "a3")) (rf "tyAliasRhs" (PVar "a4")) (rf "tyAliasOrigin" (PVar "a5")) (rf "tyAliasNameLoc" (PVar "a6"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "10"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a2")) (EApp (EApp (EVar "sexpList") (EApp (EVar "sexpOpt") (EVar "sexpKindAnn"))) (EVar "a3")) (EApp (EVar "sexpTy") (EVar "a4")) (EApp (EVar "sexpTyConOrigin") (EVar "a5")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a6")))))
(DFunDef false "sexpDecl" ((PRec "DNewtype" ((rf "newtypePub" (PVar "a0")) (rf "newtypeName" (PVar "a1")) (rf "newtypeParams" (PVar "a2")) (rf "newtypeParamKinds" (PVar "a3")) (rf "newtypeCtor" (PVar "a4")) (rf "newtypeCtorBinders" (PVar "a5")) (rf "newtypeFieldTy" (PVar "a6")) (rf "newtypeDerives" (PVar "a7")) (rf "newtypeOrigin" (PVar "a8")) (rf "newtypeNameLoc" (PVar "a9"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "11"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a2")) (EApp (EApp (EVar "sexpList") (EApp (EVar "sexpOpt") (EVar "sexpKindAnn"))) (EVar "a3")) (EApp (EVar "sexpString") (EVar "a4")) (EApp (EApp (EVar "sexpList") (EApp (EApp (EVar "sexpPair") (EVar "sexpString")) (EVar "sexpKindAnn"))) (EVar "a5")) (EApp (EVar "sexpTy") (EVar "a6")) (EApp (EApp (EVar "sexpList") (EVar "sexpDeriveRef")) (EVar "a7")) (EApp (EVar "sexpTyConOrigin") (EVar "a8")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a9")))))
(DFunDef false "sexpDecl" ((PCon "DLetGroup" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "12"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpLetBind")) (EVar "a1")))))
(DFunDef false "sexpDecl" ((PCon "DAttrib" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "13"))) (EApp (EApp (EVar "sexpList") (EVar "sexpAttr")) (EVar "a0")) (EApp (EVar "sexpDecl") (EVar "a1")))))
(DTypeSig false "dfltLoc" (TyCon "Loc"))
(DFunDef false "dfltLoc" () (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 1))) (ELit (LInt 0))) (ELit (LInt 1))) (ELit (LInt 0))))
(DTypeSig false "dfltLit" (TyCon "Lit"))
(DFunDef false "dfltLit" () (EVar "LUnit"))
(DTypeSig false "dfltTyConOrigin" (TyCon "TyConOrigin"))
(DFunDef false "dfltTyConOrigin" () (EVar "OriginUnresolved"))
(DTypeSig false "dfltTy" (TyCon "Ty"))
(DFunDef false "dfltTy" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString ""))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "dfltTyConOrigin")))))
(DTypeSig false "dfltEffParamTy" (TyCon "EffParamTy"))
(DFunDef false "dfltEffParamTy" () (EVar "EPTop"))
(DTypeSig false "dfltKindAnn" (TyCon "KindAnn"))
(DFunDef false "dfltKindAnn" () (EVar "KindType"))
(DTypeSig false "dfltRoute" (TyCon "Route"))
(DFunDef false "dfltRoute" () (EVar "RNone"))
(DTypeSig false "dfltEvVal" (TyCon "EvVal"))
(DFunDef false "dfltEvVal" () (EApp (EVar "EvOne") (EVar "dfltRoute")))
(DTypeSig false "dfltAddr" (TyCon "Addr"))
(DFunDef false "dfltAddr" () (EVar "AGlobal"))
(DTypeSig false "dfltPat" (TyCon "Pat"))
(DFunDef false "dfltPat" () (EVar "PWild"))
(DTypeSig false "dfltGuard" (TyCon "Guard"))
(DFunDef false "dfltGuard" () (EApp (EVar "GBool") (EVar "dfltExpr")))
(DTypeSig false "dfltDoStmt" (TyCon "DoStmt"))
(DFunDef false "dfltDoStmt" () (EApp (EVar "DoExpr") (EVar "dfltExpr")))
(DTypeSig false "dfltInterpPart" (TyCon "InterpPart"))
(DFunDef false "dfltInterpPart" () (EApp (EVar "InterpStr") (ELit (LString ""))))
(DTypeSig false "dfltSection" (TyCon "Section"))
(DFunDef false "dfltSection" () (EApp (EVar "SecBare") (ELit (LString ""))))
(DTypeSig false "dfltExpr" (TyCon "Expr"))
(DFunDef false "dfltExpr" () (EApp (EVar "ELit") (EVar "dfltLit")))
(DTypeSig false "dfltUsePath" (TyCon "UsePath"))
(DFunDef false "dfltUsePath" () (EApp (EVar "UseName") (EListLit)))
(DTypeSig false "dfltDataVis" (TyCon "DataVis"))
(DFunDef false "dfltDataVis" () (EVar "VisPrivate"))
(DTypeSig false "dfltConPayload" (TyCon "ConPayload"))
(DFunDef false "dfltConPayload" () (EApp (EVar "ConPos") (EListLit)))
(DTypeSig false "dfltAttr" (TyCon "Attr"))
(DFunDef false "dfltAttr" () (EVar "AttrInline"))
(DTypeSig false "dfltDecl" (TyCon "Decl"))
(DFunDef false "dfltDecl" () (EApp (EApp (EApp (EApp (EVar "DTypeSig") (EVar "False")) (ELit (LString ""))) (EVar "dfltTy")) (EVar "dfltLoc")))
(DTypeSig false "readLit" (TyFun (TyCon "SexpCursor") (TyCon "Lit")))
(DFunDef false "readLit" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readLitTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readLitBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readLitBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Lit"))))
(DFunDef false "readLitBare" ((PLit (LInt 7)) PWild) (EVar "LUnit"))
(DFunDef false "readLitBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltLit")))
(DTypeSig false "readLitTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Lit"))))
(DFunDef false "readLitTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readInt") (EVar "cur"))) (DoExpr (EApp (EVar "LInt") (EVar "a0")))))
(DFunDef false "readLitTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readFloat") (EVar "cur"))) (DoExpr (EApp (EVar "LFloat") (EVar "a0")))))
(DFunDef false "readLitTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readInt") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "LU64") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readLitTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readInt") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "LI64") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readLitTagged" ((PLit (LInt 4)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "LString") (EVar "a0")))))
(DFunDef false "readLitTagged" ((PLit (LInt 5)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "LChar") (EVar "a0")))))
(DFunDef false "readLitTagged" ((PLit (LInt 6)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoExpr (EApp (EVar "LBool") (EVar "a0")))))
(DFunDef false "readLitTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltLit")))
(DTypeSig false "readTyConOrigin" (TyFun (TyCon "SexpCursor") (TyCon "TyConOrigin")))
(DFunDef false "readTyConOrigin" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readTyConOriginTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readTyConOriginBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readTyConOriginBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "TyConOrigin"))))
(DFunDef false "readTyConOriginBare" ((PLit (LInt 0)) PWild) (EVar "OriginUnresolved"))
(DFunDef false "readTyConOriginBare" ((PLit (LInt 1)) PWild) (EVar "OriginBuiltin"))
(DFunDef false "readTyConOriginBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltTyConOrigin")))
(DTypeSig false "readTyConOriginTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "TyConOrigin"))))
(DFunDef false "readTyConOriginTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "OriginModule") (EVar "a0")))))
(DFunDef false "readTyConOriginTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltTyConOrigin")))
(DTypeSig false "readTy" (TyFun (TyCon "SexpCursor") (TyCon "Ty")))
(DFunDef false "readTy" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readTyTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readTyBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readTyBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Ty"))))
(DFunDef false "readTyBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltTy")))
(DTypeSig false "readTyTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Ty"))))
(DFunDef false "readTyTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoExpr (ERecordCreate "TyCon" ((fa "tyConName" (EVar "a0")) (fa "tyConLoc" (EVar "a1")) (fa "tyConOrigin" (EVar "a2")))))))
(DFunDef false "readTyTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "TyVar") (EVar "a0")))))
(DFunDef false "readTyTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readTy") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "TyApp") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readTyTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readTy") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "TyFun") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readTyTagged" ((PLit (LInt 4)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readTy")) (EVar "cur"))) (DoExpr (EApp (EVar "TyTuple") (EVar "a0")))))
(DFunDef false "readTyTagged" ((PLit (LInt 5)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readEffAtomTy")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readTy") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "TyEffect") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readTyTagged" ((PLit (LInt 6)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readConstraint")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readTy") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "TyConstrained") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readTyTagged" ((PLit (LInt 7)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "readOpt") (EVar "readEffAtomTy")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "TyNamed") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readTyTagged" ((PLit (LInt 8)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readEffParamTy")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "TyQual") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readTyTagged" ((PLit (LInt 9)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readEffAtomTy")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "TyRow") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readTyTagged" ((PLit (LInt 10)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readEffParamTy")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "TyAuth") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readTyTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltTy")))
(DTypeSig false "readEffAtomTy" (TyFun (TyCon "SexpCursor") (TyCon "EffAtomTy")))
(DFunDef false "readEffAtomTy" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readEffParamTy") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ERecordCreate "EffAtomTy" ((fa "eatLabel" (EVar "a0")) (fa "eatOrigin" (EVar "a1")) (fa "eatParam" (EVar "a2")) (fa "eatLoc" (EVar "a3")) (fa "eatPattern" (EVar "a4")))))))
(DTypeSig false "readEffParamTy" (TyFun (TyCon "SexpCursor") (TyCon "EffParamTy")))
(DFunDef false "readEffParamTy" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readEffParamTyTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readEffParamTyBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readEffParamTyBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "EffParamTy"))))
(DFunDef false "readEffParamTyBare" ((PLit (LInt 0)) PWild) (EVar "EPTop"))
(DFunDef false "readEffParamTyBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltEffParamTy")))
(DTypeSig false "readEffParamTyTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "EffParamTy"))))
(DFunDef false "readEffParamTyTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "EPLit") (EVar "a0")))))
(DFunDef false "readEffParamTyTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "EPName") (EVar "a0")))))
(DFunDef false "readEffParamTyTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoExpr (EApp (EVar "EPSet") (EVar "a0")))))
(DFunDef false "readEffParamTyTagged" ((PLit (LInt 4)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EApp (EApp (EVar "readPair") (EVar "readString")) (EVar "readEffParamTy"))) (EVar "cur"))) (DoExpr (EApp (EVar "EPProduct") (EVar "a0")))))
(DFunDef false "readEffParamTyTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltEffParamTy")))
(DTypeSig false "readConstraint" (TyFun (TyCon "SexpCursor") (TyCon "Constraint")))
(DFunDef false "readConstraint" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readTy")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ERecordCreate "Constraint" ((fa "constraintHead" (EVar "a0")) (fa "constraintArgs" (EVar "a1")) (fa "constraintOrigin" (EVar "a2")))))))
(DTypeSig false "readKindAnn" (TyFun (TyCon "SexpCursor") (TyCon "KindAnn")))
(DFunDef false "readKindAnn" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readKindAnnTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readKindAnnBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readKindAnnBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "KindAnn"))))
(DFunDef false "readKindAnnBare" ((PLit (LInt 0)) PWild) (EVar "KindType"))
(DFunDef false "readKindAnnBare" ((PLit (LInt 1)) PWild) (EVar "KindEffect"))
(DFunDef false "readKindAnnBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltKindAnn")))
(DTypeSig false "readKindAnnTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "KindAnn"))))
(DFunDef false "readKindAnnTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "KindAuthority") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DFunDef false "readKindAnnTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readKindAnn") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readKindAnn") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "KindArrow") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readKindAnnTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltKindAnn")))
(DTypeSig false "readRoute" (TyFun (TyCon "SexpCursor") (TyCon "Route")))
(DFunDef false "readRoute" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readRouteTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readRouteBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readRouteBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Route"))))
(DFunDef false "readRouteBare" ((PLit (LInt 0)) PWild) (EVar "RNone"))
(DFunDef false "readRouteBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltRoute")))
(DTypeSig false "readRouteTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Route"))))
(DFunDef false "readRouteTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readRoute")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "cursorList") (EVar "readRoute")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "RKey") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readRouteTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "RDict") (EVar "a0")))))
(DFunDef false "readRouteTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "RDictFwd") (EVar "a0")))))
(DFunDef false "readRouteTagged" ((PLit (LInt 4)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readRoute")) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "RLocal") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readRouteTagged" ((PLit (LInt 5)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "RScalar") (EVar "a0")))))
(DFunDef false "readRouteTagged" ((PLit (LInt 6)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readRoute") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readInt")) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "RProj") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readRouteTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltRoute")))
(DTypeSig false "readEvVal" (TyFun (TyCon "SexpCursor") (TyCon "EvVal")))
(DFunDef false "readEvVal" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readEvValTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readEvValBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readEvValBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "EvVal"))))
(DFunDef false "readEvValBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltEvVal")))
(DTypeSig false "readEvValTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "EvVal"))))
(DFunDef false "readEvValTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readRoute") (EVar "cur"))) (DoExpr (EApp (EVar "EvOne") (EVar "a0")))))
(DFunDef false "readEvValTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readRoute")) (EVar "cur"))) (DoExpr (EApp (EVar "EvMany") (EVar "a0")))))
(DFunDef false "readEvValTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readRoute") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "cursorList") (EVar "readRoute")) (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EApp (EVar "cursorList") (EVar "readRoute")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "EvMethod") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")) (EVar "a4")))))
(DFunDef false "readEvValTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "readOpt") (EVar "readFloat")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readRoute") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EvLit") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readEvValTagged" ((PLit (LInt 4)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "EvHead") (EVar "a0")))))
(DFunDef false "readEvValTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltEvVal")))
(DTypeSig false "readEvEntry" (TyFun (TyCon "SexpCursor") (TyCon "EvEntry")))
(DFunDef false "readEvEntry" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readEvId") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readEvVal") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EvEntry") (EVar "a0")) (EVar "a1")))))
(DTypeSig false "readAddr" (TyFun (TyCon "SexpCursor") (TyCon "Addr")))
(DFunDef false "readAddr" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readAddrTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readAddrBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readAddrBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Addr"))))
(DFunDef false "readAddrBare" ((PLit (LInt 1)) PWild) (EVar "AGlobal"))
(DFunDef false "readAddrBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltAddr")))
(DTypeSig false "readAddrTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Addr"))))
(DFunDef false "readAddrTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readInt") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "ALocal") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readAddrTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltAddr")))
(DTypeSig false "readPat" (TyFun (TyCon "SexpCursor") (TyCon "Pat")))
(DFunDef false "readPat" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readPatTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readPatBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readPatBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Pat"))))
(DFunDef false "readPatBare" ((PLit (LInt 1)) PWild) (EVar "PWild"))
(DFunDef false "readPatBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltPat")))
(DTypeSig false "readPatTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Pat"))))
(DFunDef false "readPatTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readBinderId") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "PVar") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readPatTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readLit") (EVar "cur"))) (DoExpr (EApp (EVar "PLit") (EVar "a0")))))
(DFunDef false "readPatTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readPat")) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "PCon") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readPatTagged" ((PLit (LInt 4)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readPat") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readPat") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "PCons") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readPatTagged" ((PLit (LInt 5)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readPat")) (EVar "cur"))) (DoExpr (EApp (EVar "PTuple") (EVar "a0")))))
(DFunDef false "readPatTagged" ((PLit (LInt 6)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readPat")) (EVar "cur"))) (DoExpr (EApp (EVar "PList") (EVar "a0")))))
(DFunDef false "readPatTagged" ((PLit (LInt 7)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readBinderId") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readPat") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "PAs") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DFunDef false "readPatTagged" ((PLit (LInt 8)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readLit") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readLit") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readBool") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "PRng") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readPatTagged" ((PLit (LInt 9)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readRecPatField")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readBool") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "PRec") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readPatTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltPat")))
(DTypeSig false "readRecPatField" (TyFun (TyCon "SexpCursor") (TyCon "RecPatField")))
(DFunDef false "readRecPatField" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readBinderId") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "readOpt") (EVar "readPat")) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "RecPatField") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DTypeSig false "readGuard" (TyFun (TyCon "SexpCursor") (TyCon "Guard")))
(DFunDef false "readGuard" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readGuardTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readGuardBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readGuardBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Guard"))))
(DFunDef false "readGuardBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltGuard")))
(DTypeSig false "readGuardTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Guard"))))
(DFunDef false "readGuardTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EVar "GBool") (EVar "a0")))))
(DFunDef false "readGuardTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readPat") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "GBind") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readGuardTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltGuard")))
(DTypeSig false "readArm" (TyFun (TyCon "SexpCursor") (TyCon "Arm")))
(DFunDef false "readArm" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readPat") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readGuard")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DTypeSig false "readDoStmt" (TyFun (TyCon "SexpCursor") (TyCon "DoStmt")))
(DFunDef false "readDoStmt" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readDoStmtTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readDoStmtBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readDoStmtBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "DoStmt"))))
(DFunDef false "readDoStmtBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltDoStmt")))
(DTypeSig false "readDoStmtTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "DoStmt"))))
(DFunDef false "readDoStmtTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EVar "DoExpr") (EVar "a0")))))
(DFunDef false "readDoStmtTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readPat") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "DoBind") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readDoStmtTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readPat") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EVar "readLoc") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")) (EVar "a4")))))
(DFunDef false "readDoStmtTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "DoAssign") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readDoStmtTagged" ((PLit (LInt 4)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readDoStmtTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltDoStmt")))
(DTypeSig false "readInterpPart" (TyFun (TyCon "SexpCursor") (TyCon "InterpPart")))
(DFunDef false "readInterpPart" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readInterpPartTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readInterpPartBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readInterpPartBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "InterpPart"))))
(DFunDef false "readInterpPartBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltInterpPart")))
(DTypeSig false "readInterpPartTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "InterpPart"))))
(DFunDef false "readInterpPartTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "InterpStr") (EVar "a0")))))
(DFunDef false "readInterpPartTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EVar "InterpExpr") (EVar "a0")))))
(DFunDef false "readInterpPartTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltInterpPart")))
(DTypeSig false "readGuardArm" (TyFun (TyCon "SexpCursor") (TyCon "GuardArm")))
(DFunDef false "readGuardArm" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readGuard")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "GuardArm") (EVar "a0")) (EVar "a1")))))
(DTypeSig false "readFieldAssign" (TyFun (TyCon "SexpCursor") (TyCon "FieldAssign")))
(DFunDef false "readFieldAssign" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "FieldAssign") (EVar "a0")) (EVar "a1")))))
(DTypeSig false "readSection" (TyFun (TyCon "SexpCursor") (TyCon "Section")))
(DFunDef false "readSection" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readSectionTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readSectionBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readSectionBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Section"))))
(DFunDef false "readSectionBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltSection")))
(DTypeSig false "readSectionTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Section"))))
(DFunDef false "readSectionTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "SecBare") (EVar "a0")))))
(DFunDef false "readSectionTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "SecRight") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readSectionTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "SecLeft") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readSectionTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltSection")))
(DTypeSig false "readFunClause" (TyFun (TyCon "SexpCursor") (TyCon "FunClause")))
(DFunDef false "readFunClause" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readPat")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "FunClause") (EVar "a0")) (EVar "a1")))))
(DTypeSig false "readLetBind" (TyFun (TyCon "SexpCursor") (TyCon "LetBind")))
(DFunDef false "readLetBind" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readFunClause")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readBinderId") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DTypeSig false "readExpr" (TyFun (TyCon "SexpCursor") (TyCon "Expr")))
(DFunDef false "readExpr" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readExprTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readExprBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readExprBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Expr"))))
(DFunDef false "readExprBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltExpr")))
(DTypeSig false "readExprTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Expr"))))
(DFunDef false "readExprTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readLit") (EVar "cur"))) (DoExpr (EApp (EVar "ELit") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "EVar") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EApp") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readPat")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "ELam") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 4)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readPat") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")) (EVar "a4")))))
(DFunDef false "readExprTagged" ((PLit (LInt 5)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readArm")) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EMatch") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 6)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "EIf") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readExprTagged" ((PLit (LInt 7)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readEvId") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DFunDef false "readExprTagged" ((PLit (LInt 8)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readEvId") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "EUnOp") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readExprTagged" ((PLit (LInt 9)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "EInfix") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readExprTagged" ((PLit (LInt 10)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readEvId") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "EFieldAccess") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readExprTagged" ((PLit (LInt 11)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readExpr")) (EVar "cur"))) (DoExpr (EApp (EVar "ETuple") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 12)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readExpr")) (EVar "cur"))) (DoExpr (EApp (EVar "EListLit") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 13)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readExpr")) (EVar "cur"))) (DoExpr (EApp (EVar "EArrayLit") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 14)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readBool") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "ERangeList") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readExprTagged" ((PLit (LInt 15)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readBool") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "ERangeArray") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readExprTagged" ((PLit (LInt 16)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readBool") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "ESlice") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DFunDef false "readExprTagged" ((PLit (LInt 17)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readLetBind")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "ELetGroup") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 18)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readSection") (EVar "cur"))) (DoExpr (EApp (EVar "ESection") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 19)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EIndex") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 20)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readTy") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EAnnot") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 21)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readTy") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EHeadAnnot") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 22)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readDoStmt")) (EVar "cur"))) (DoExpr (EApp (EVar "EBlock") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 23)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readDoStmt")) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EDo") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 24)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readInterpPart")) (EVar "cur"))) (DoExpr (EApp (EVar "EStringInterp") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 25)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readGuardArm")) (EVar "cur"))) (DoExpr (EApp (EVar "EGuards") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 26)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readFieldAssign")) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "ERecordCreate") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 27)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readFieldAssign")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readEvId") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "ERecordUpdate") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readExprTagged" ((PLit (LInt 28)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "cursorList") (EVar "readFieldAssign")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readExprTagged" ((PLit (LInt 29)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EApp (EApp (EVar "readPair") (EVar "readExpr")) (EVar "readExpr"))) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EMapLit") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 30)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readExpr")) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "ESetLit") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 31)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EAsPat") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 32)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "EMethodRef") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 33)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "EDictApp") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 34)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readAddr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EVarAt") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 35)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readInt") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EVarId") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 36)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readEvId") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "EMethodAt") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readExprTagged" ((PLit (LInt 37)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readEvId") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EDictAt") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 38)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "ELoc") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 39)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EDoOrigin") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 40)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readEvId") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "ENumLit") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readExprTagged" ((PLit (LInt 41)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readEvId") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "EWideLit") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DFunDef false "readExprTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltExpr")))
(DTypeSig false "readUseMember" (TyFun (TyCon "SexpCursor") (TyCon "UseMember")))
(DFunDef false "readUseMember" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "readOpt") (EVar "readString")) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DTypeSig false "readUsePath" (TyFun (TyCon "SexpCursor") (TyCon "UsePath")))
(DFunDef false "readUsePath" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readUsePathTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readUsePathBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readUsePathBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "UsePath"))))
(DFunDef false "readUsePathBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltUsePath")))
(DTypeSig false "readUsePathTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "UsePath"))))
(DFunDef false "readUsePathTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoExpr (EApp (EVar "UseName") (EVar "a0")))))
(DFunDef false "readUsePathTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readUseMember")) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "UseGroup") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readUsePathTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoExpr (EApp (EVar "UseWild") (EVar "a0")))))
(DFunDef false "readUsePathTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "UseAlias") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readUsePathTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltUsePath")))
(DTypeSig false "readPropParam" (TyFun (TyCon "SexpCursor") (TyCon "PropParam")))
(DFunDef false "readPropParam" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "PropParam") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DTypeSig false "readMethodDefault" (TyFun (TyCon "SexpCursor") (TyCon "MethodDefault")))
(DFunDef false "readMethodDefault" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readPat")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "MethodDefault") (EVar "a0")) (EVar "a1")))))
(DTypeSig false "readIfaceMethod" (TyFun (TyCon "SexpCursor") (TyCon "IfaceMethod")))
(DFunDef false "readIfaceMethod" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "readOpt") (EVar "readMethodDefault")) (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DTypeSig false "readSuper" (TyFun (TyCon "SexpCursor") (TyCon "Super")))
(DFunDef false "readSuper" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ERecordCreate "Super" ((fa "superHead" (EVar "a0")) (fa "superParams" (EVar "a1")) (fa "superOrigin" (EVar "a2")))))))
(DTypeSig false "readRequire" (TyFun (TyCon "SexpCursor") (TyCon "Require")))
(DFunDef false "readRequire" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readTy")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ERecordCreate "Require" ((fa "requireHead" (EVar "a0")) (fa "requireArgs" (EVar "a1")) (fa "requireOrigin" (EVar "a2")))))))
(DTypeSig false "readImplMethod" (TyFun (TyCon "SexpCursor") (TyCon "ImplMethod")))
(DFunDef false "readImplMethod" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readPat")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "ImplMethod") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DTypeSig false "readDataVis" (TyFun (TyCon "SexpCursor") (TyCon "DataVis")))
(DFunDef false "readDataVis" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readDataVisTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readDataVisBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readDataVisBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "DataVis"))))
(DFunDef false "readDataVisBare" ((PLit (LInt 0)) PWild) (EVar "VisPrivate"))
(DFunDef false "readDataVisBare" ((PLit (LInt 1)) PWild) (EVar "VisAbstract"))
(DFunDef false "readDataVisBare" ((PLit (LInt 2)) PWild) (EVar "VisPublic"))
(DFunDef false "readDataVisBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltDataVis")))
(DTypeSig false "readDataVisTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "DataVis"))))
(DFunDef false "readDataVisTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltDataVis")))
(DTypeSig false "readField" (TyFun (TyCon "SexpCursor") (TyCon "Field")))
(DFunDef false "readField" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "Field") (EVar "a0")) (EVar "a1")))))
(DTypeSig false "readConPayload" (TyFun (TyCon "SexpCursor") (TyCon "ConPayload")))
(DFunDef false "readConPayload" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readConPayloadTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readConPayloadBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readConPayloadBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "ConPayload"))))
(DFunDef false "readConPayloadBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltConPayload")))
(DTypeSig false "readConPayloadTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "ConPayload"))))
(DFunDef false "readConPayloadTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readTy")) (EVar "cur"))) (DoExpr (EApp (EVar "ConPos") (EVar "a0")))))
(DFunDef false "readConPayloadTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readField")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readBool") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "ConNamed") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readConPayloadTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltConPayload")))
(DTypeSig false "readVariant" (TyFun (TyCon "SexpCursor") (TyCon "Variant")))
(DFunDef false "readVariant" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readConPayload") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "Variant") (EVar "a0")) (EVar "a1")))))
(DTypeSig false "readAttr" (TyFun (TyCon "SexpCursor") (TyCon "Attr")))
(DFunDef false "readAttr" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readAttrTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readAttrBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readAttrBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Attr"))))
(DFunDef false "readAttrBare" ((PLit (LInt 1)) PWild) (EVar "AttrInline"))
(DFunDef false "readAttrBare" ((PLit (LInt 2)) PWild) (EVar "AttrMustUse"))
(DFunDef false "readAttrBare" ((PLit (LInt 3)) PWild) (EVar "AttrNoInline"))
(DFunDef false "readAttrBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltAttr")))
(DTypeSig false "readAttrTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Attr"))))
(DFunDef false "readAttrTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "readOpt") (EVar "readString")) (EVar "cur"))) (DoExpr (EApp (EVar "AttrDeprecated") (EVar "a0")))))
(DFunDef false "readAttrTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltAttr")))
(DTypeSig false "readDeriveRef" (TyFun (TyCon "SexpCursor") (TyCon "DeriveRef")))
(DFunDef false "readDeriveRef" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "DeriveRef") (EVar "a0")) (EVar "a1")))))
(DTypeSig false "readExternDecl" (TyFun (TyCon "SexpCursor") (TyCon "ExternDecl")))
(DFunDef false "readExternDecl" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EApp (EVar "cursorList") (EVar "readExternBind")) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ERecordCreate "ExternDecl" ((fa "edPub" (EVar "a0")) (fa "edName" (EVar "a1")) (fa "edTy" (EVar "a2")) (fa "edLoc" (EVar "a3")) (fa "edBinds" (EVar "a4")))))))
(DTypeSig false "readExternBind" (TyFun (TyCon "SexpCursor") (TyCon "ExternBind")))
(DFunDef false "readExternBind" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ERecordCreate "ExternBind" ((fa "ebHost" (EVar "a0")) (fa "ebSymbol" (EVar "a1")) (fa "ebLoc" (EVar "a2")))))))
(DTypeSig false "readDecl" (TyFun (TyCon "SexpCursor") (TyCon "Decl")))
(DFunDef false "readDecl" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readDeclTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readDeclBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readDeclBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Decl"))))
(DFunDef false "readDeclBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltDecl")))
(DTypeSig false "readDeclTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Decl"))))
(DFunDef false "readDeclTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readLoc") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "DTypeSig") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DFunDef false "readDeclTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExternDecl") (EVar "cur"))) (DoExpr (EApp (EVar "DExtern") (EVar "a0")))))
(DFunDef false "readDeclTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "cursorList") (EVar "readPat")) (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a5") (EApp (EVar "readBinderId") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")) (EVar "a4")) (EVar "a5")))))
(DFunDef false "readDeclTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readDataVis") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "cursorList") (EApp (EVar "readOpt") (EVar "readKindAnn"))) (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EApp (EVar "cursorList") (EVar "readVariant")) (EVar "cur"))) (DoLet false false (PVar "a5") (EApp (EApp (EVar "cursorList") (EApp (EVar "cursorList") (EApp (EApp (EVar "readPair") (EVar "readString")) (EVar "readKindAnn")))) (EVar "cur"))) (DoLet false false (PVar "a6") (EApp (EApp (EVar "cursorList") (EVar "readDeriveRef")) (EVar "cur"))) (DoLet false false (PVar "a7") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false (PVar "a8") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a9") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoExpr (ERecordCreate "DData" ((fa "dataVis" (EVar "a0")) (fa "dataName" (EVar "a1")) (fa "dataParams" (EVar "a2")) (fa "dataParamKinds" (EVar "a3")) (fa "dataCtors" (EVar "a4")) (fa "dataCtorBinders" (EVar "a5")) (fa "dataDerives" (EVar "a6")) (fa "dataOrigin" (EVar "a7")) (fa "dataExtern" (EVar "a8")) (fa "dataNameLoc" (EVar "a9")))))))
(DFunDef false "readDeclTagged" ((PLit (LInt 4)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readUsePath") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readLoc") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "DUse") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readDeclTagged" ((PLit (LInt 5)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "readOpt") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "cursorList") (EApp (EApp (EVar "readPair") (EVar "readString")) (EVar "readString"))) (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false (PVar "a5") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DEffect") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")) (EVar "a4")) (EVar "a5")))))
(DFunDef false "readDeclTagged" ((PLit (LInt 6)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "cursorList") (EVar "readPropParam")) (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DFunDef false "readDeclTagged" ((PLit (LInt 7)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "DTest") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readDeclTagged" ((PLit (LInt 8)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EApp (EVar "cursorList") (EApp (EVar "readOpt") (EVar "readKindAnn"))) (EVar "cur"))) (DoLet false false (PVar "a5") (EApp (EApp (EVar "cursorList") (EVar "readSuper")) (EVar "cur"))) (DoLet false false (PVar "a6") (EApp (EApp (EVar "cursorList") (EVar "readIfaceMethod")) (EVar "cur"))) (DoLet false false (PVar "a7") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false (PVar "a8") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoExpr (ERecordCreate "DInterface" ((fa "pub" (EVar "a0")) (fa "def" (EVar "a1")) (fa "name" (EVar "a2")) (fa "typarams" (EVar "a3")) (fa "typaramKinds" (EVar "a4")) (fa "supers" (EVar "a5")) (fa "methods" (EVar "a6")) (fa "ifaceOrigin" (EVar "a7")) (fa "ifaceNameLoc" (EVar "a8")))))))
(DFunDef false "readDeclTagged" ((PLit (LInt 9)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "cursorList") (EVar "readTy")) (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "cursorList") (EVar "readRequire")) (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EApp (EVar "cursorList") (EVar "readImplMethod")) (EVar "cur"))) (DoLet false false (PVar "a5") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false (PVar "a6") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoExpr (ERecordCreate "DImpl" ((fa "pub" (EVar "a0")) (fa "iface" (EVar "a1")) (fa "tys" (EVar "a2")) (fa "reqs" (EVar "a3")) (fa "methods" (EVar "a4")) (fa "implOrigin" (EVar "a5")) (fa "implIfaceLoc" (EVar "a6")))))))
(DFunDef false "readDeclTagged" ((PLit (LInt 10)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "cursorList") (EApp (EVar "readOpt") (EVar "readKindAnn"))) (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false (PVar "a5") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false (PVar "a6") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoExpr (ERecordCreate "DTypeAlias" ((fa "tyAliasPub" (EVar "a0")) (fa "tyAliasName" (EVar "a1")) (fa "tyAliasParams" (EVar "a2")) (fa "tyAliasParamKinds" (EVar "a3")) (fa "tyAliasRhs" (EVar "a4")) (fa "tyAliasOrigin" (EVar "a5")) (fa "tyAliasNameLoc" (EVar "a6")))))))
(DFunDef false "readDeclTagged" ((PLit (LInt 11)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "cursorList") (EApp (EVar "readOpt") (EVar "readKindAnn"))) (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a5") (EApp (EApp (EVar "cursorList") (EApp (EApp (EVar "readPair") (EVar "readString")) (EVar "readKindAnn"))) (EVar "cur"))) (DoLet false false (PVar "a6") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false (PVar "a7") (EApp (EApp (EVar "cursorList") (EVar "readDeriveRef")) (EVar "cur"))) (DoLet false false (PVar "a8") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false (PVar "a9") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoExpr (ERecordCreate "DNewtype" ((fa "newtypePub" (EVar "a0")) (fa "newtypeName" (EVar "a1")) (fa "newtypeParams" (EVar "a2")) (fa "newtypeParamKinds" (EVar "a3")) (fa "newtypeCtor" (EVar "a4")) (fa "newtypeCtorBinders" (EVar "a5")) (fa "newtypeFieldTy" (EVar "a6")) (fa "newtypeDerives" (EVar "a7")) (fa "newtypeOrigin" (EVar "a8")) (fa "newtypeNameLoc" (EVar "a9")))))))
(DFunDef false "readDeclTagged" ((PLit (LInt 12)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readLetBind")) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "DLetGroup") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readDeclTagged" ((PLit (LInt 13)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readAttr")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readDecl") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "DAttrib") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readDeclTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltDecl")))
# MARK
(DUse false (UseWild ("frontend" "ast")))
(DUse false (UseGroup ("array") ((mem "fromList" false))))
(DUse false (UseGroup ("list") ((mem "splitAt" false))))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "SexpCursor" false) (mem "SexpError" true) (mem "cursorAdvance" false) (mem "cursorAtEnd" false) (mem "cursorAtom" false) (mem "cursorClose" false) (mem "cursorFail" false) (mem "cursorFailed" false) (mem "cursorInt" false) (mem "cursorList" false) (mem "cursorOf" false) (mem "cursorOffset" false) (mem "cursorOpen" false) (mem "cursorPeek" false) (mem "cursorChar" false))))
(DTypeSig true "declsSExp" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "SExp")))
(DFunDef false "declsSExp" ((PVar "ds")) (EApp (EApp (EVar "sexpList") (EVar "sexpDecl")) (EVar "ds")))
(DTypeSig true "evEntriesSExp" (TyFun (TyApp (TyCon "List") (TyCon "EvEntry")) (TyCon "SExp")))
(DFunDef false "evEntriesSExp" ((PVar "es")) (EApp (EApp (EVar "sexpList") (EVar "sexpEvEntry")) (EVar "es")))
(DTypeSig true "readDecls" (TyFun (TyCon "SexpCursor") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "readDecls" ((PVar "cur")) (EApp (EApp (EApp (EVar "checked") (ELit (LString "decls"))) (EVar "cur")) (EApp (EApp (EVar "cursorList") (EVar "readDecl")) (EVar "cur"))))
(DTypeSig true "readEvEntries" (TyFun (TyCon "SexpCursor") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyApp (TyCon "List") (TyCon "EvEntry")))))
(DFunDef false "readEvEntries" ((PVar "cur")) (EApp (EApp (EApp (EVar "checked") (ELit (LString "evidence"))) (EVar "cur")) (EApp (EApp (EVar "cursorList") (EVar "readEvEntry")) (EVar "cur"))))
(DTypeSig true "decodeDecls" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "decodeDecls" ((PVar "text")) (EApp (EApp (EVar "decodeAll") (EVar "readDecls")) (EVar "text")))
(DTypeSig true "decodeEvEntries" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyApp (TyCon "List") (TyCon "EvEntry")))))
(DFunDef false "decodeEvEntries" ((PVar "text")) (EApp (EApp (EVar "decodeAll") (EVar "readEvEntries")) (EVar "text")))
(DTypeSig false "decodeAll" (TyFun (TyFun (TyCon "SexpCursor") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a"))) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))))
(DFunDef false "decodeAll" ((PVar "reader") (PVar "text")) (EBlock (DoLet false false (PVar "cur") (EApp (EVar "cursorOf") (EVar "text"))) (DoExpr (EMatch (EApp (EVar "reader") (EVar "cur")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "v")) () (EIf (EApp (EVar "cursorAtEnd") (EVar "cur")) (EApp (EVar "Ok") (EVar "v")) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (EApp (EVar "cursorOffset") (EVar "cur"))) (fa "sePath" (ELit (LString ""))) (fa "seWhat" (ELit (LString "trailing text after the encoded value"))))))))))))
(DTypeSig false "checked" (TyFun (TyCon "String") (TyFun (TyCon "SexpCursor") (TyFun (TyVar "a") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a"))))))
(DFunDef false "checked" ((PVar "path") (PVar "cur") (PVar "v")) (EIf (EApp (EVar "cursorFailed") (EVar "cur")) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (EApp (EVar "cursorOffset") (EVar "cur"))) (fa "sePath" (EVar "path")) (fa "seWhat" (ELit (LString "malformed or truncated encoding")))))) (EApp (EVar "Ok") (EVar "v"))))
(DTypeSig false "sexpInt" (TyFun (TyCon "Int") (TyCon "SExp")))
(DFunDef false "sexpInt" ((PVar "n")) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "n"))))
(DTypeSig false "sexpString" (TyFun (TyCon "String") (TyCon "SExp")))
(DFunDef false "sexpString" ((PVar "s")) (EApp (EVar "SAtom") (EVar "s")))
(DTypeSig true "sexpBool" (TyFun (TyCon "Bool") (TyCon "SExp")))
(DFunDef false "sexpBool" ((PVar "b")) (EApp (EVar "SAtom") (EIf (EVar "b") (ELit (LString "t")) (ELit (LString "f")))))
(DTypeSig false "sexpFloat" (TyFun (TyCon "Float") (TyCon "SExp")))
(DFunDef false "sexpFloat" ((PVar "f")) (EMatch (EApp (EApp (EVar "splitAt") (ELit (LInt 4))) (EApp (EMethodRef "toList") (EApp (EVar "floatToBytes64") (EVar "f")))) (arm (PTuple (PVar "hi") (PVar "lo")) () (EApp (EVar "SList") (EListLit (EApp (EVar "sexpInt") (EApp (EVar "wordOf") (EVar "hi"))) (EApp (EVar "sexpInt") (EApp (EVar "wordOf") (EVar "lo"))))))))
(DTypeSig false "sexpList" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "SExp"))))
(DFunDef false "sexpList" ((PVar "f") (PVar "xs")) (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (EVar "f")) (EVar "xs"))))
(DTypeSig false "sexpOpt" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyCon "SExp"))))
(DFunDef false "sexpOpt" (PWild (PCon "None")) (EApp (EVar "SList") (EListLit)))
(DFunDef false "sexpOpt" ((PVar "f") (PCon "Some" (PVar "x"))) (EApp (EVar "SList") (EListLit (EApp (EVar "f") (EVar "x")))))
(DTypeSig false "sexpPair" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyFun (TyVar "b") (TyCon "SExp")) (TyFun (TyTuple (TyVar "a") (TyVar "b")) (TyCon "SExp")))))
(DFunDef false "sexpPair" ((PVar "fa") (PVar "fb") (PTuple (PVar "a") (PVar "b"))) (EApp (EVar "SList") (EListLit (EApp (EVar "fa") (EVar "a")) (EApp (EVar "fb") (EVar "b")))))
(DTypeSig false "sexpLoc" (TyFun (TyCon "Loc") (TyCon "SExp")))
(DFunDef false "sexpLoc" ((PCon "Loc" (PLit (LString "")) (PLit (LInt 1)) (PLit (LInt 0)) (PLit (LInt 1)) (PLit (LInt 0)))) (EApp (EVar "SAtom") (ELit (LString "z"))))
(DFunDef false "sexpLoc" ((PCon "Loc" (PVar "f") (PVar "a") (PVar "b") (PVar "c") (PVar "d"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EVar "f")) (EApp (EVar "sexpInt") (EVar "a")) (EApp (EVar "sexpInt") (EVar "b")) (EApp (EVar "sexpInt") (EVar "c")) (EApp (EVar "sexpInt") (EVar "d")))))
(DTypeSig false "sexpEvId" (TyFun (TyCon "EvId") (TyCon "SExp")))
(DFunDef false "sexpEvId" ((PCon "EvId" (PLit (LString "")) (PVar "n"))) (EApp (EVar "sexpInt") (EVar "n")))
(DFunDef false "sexpEvId" ((PCon "EvId" (PVar "m") (PVar "n"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EVar "m")) (EApp (EVar "sexpInt") (EVar "n")))))
(DTypeSig true "sexpBinderId" (TyFun (TyCon "BinderId") (TyCon "SExp")))
(DFunDef false "sexpBinderId" ((PCon "BinderId" (PLit (LString "")) (PVar "n"))) (EApp (EVar "sexpInt") (EVar "n")))
(DFunDef false "sexpBinderId" ((PCon "BinderId" (PVar "m") (PVar "n"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EVar "m")) (EApp (EVar "sexpInt") (EVar "n")))))
(DTypeSig false "wordOf" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "wordOf" ((PVar "bytes")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "b")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 256))) (EVar "b")))) (ELit (LInt 0))) (EVar "bytes")))
(DTypeSig false "bytesOfWord" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "bytesOfWord" ((PVar "w")) (EListLit (EBinOp "%" (EBinOp "/" (EVar "w") (ELit (LInt 16777216))) (ELit (LInt 256))) (EBinOp "%" (EBinOp "/" (EVar "w") (ELit (LInt 65536))) (ELit (LInt 256))) (EBinOp "%" (EBinOp "/" (EVar "w") (ELit (LInt 256))) (ELit (LInt 256))) (EBinOp "%" (EVar "w") (ELit (LInt 256)))))
(DTypeSig false "readInt" (TyFun (TyCon "SexpCursor") (TyCon "Int")))
(DFunDef false "readInt" ((PVar "cur")) (EApp (EVar "cursorInt") (EVar "cur")))
(DTypeSig false "readString" (TyFun (TyCon "SexpCursor") (TyCon "String")))
(DFunDef false "readString" ((PVar "cur")) (EApp (EVar "cursorAtom") (EVar "cur")))
(DTypeSig true "readBool" (TyFun (TyCon "SexpCursor") (TyCon "Bool")))
(DFunDef false "readBool" ((PVar "cur")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "cursorChar") (EVar "cur"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LInt 116))) (EVar "True") (EIf (EBinOp "==" (EVar "c") (ELit (LInt 102))) (EVar "False") (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "False")))))))
(DTypeSig false "readFloat" (TyFun (TyCon "SexpCursor") (TyCon "Float")))
(DFunDef false "readFloat" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "hi") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "lo") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "hi") (ELit (LInt 0))) (EBinOp ">" (EVar "hi") (ELit (LInt 4294967295)))) (EBinOp "<" (EVar "lo") (ELit (LInt 0)))) (EBinOp ">" (EVar "lo") (ELit (LInt 4294967295)))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit (LFloat 0.0))) (EApp (EApp (EVar "bytesToFloat64") (EApp (EVar "fromList") (EBinOp "++" (EApp (EVar "bytesOfWord") (EVar "hi")) (EApp (EVar "bytesOfWord") (EVar "lo"))))) (ELit (LInt 0)))))))
(DTypeSig false "readOpt" (TyFun (TyFun (TyCon "SexpCursor") (TyVar "a")) (TyFun (TyCon "SexpCursor") (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "readOpt" ((PVar "f") (PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 41))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoExpr (EVar "None"))) (EBlock (DoLet false false (PVar "v") (EApp (EVar "f") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EVar "Some") (EVar "v"))))))))
(DTypeSig false "readPair" (TyFun (TyFun (TyCon "SexpCursor") (TyVar "a")) (TyFun (TyFun (TyCon "SexpCursor") (TyVar "b")) (TyFun (TyCon "SexpCursor") (TyTuple (TyVar "a") (TyVar "b"))))))
(DFunDef false "readPair" ((PVar "fa") (PVar "fb") (PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a") (EApp (EVar "fa") (EVar "cur"))) (DoLet false false (PVar "b") (EApp (EVar "fb") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ETuple (EVar "a") (EVar "b")))))
(DTypeSig false "readLoc" (TyFun (TyCon "SexpCursor") (TyCon "Loc")))
(DFunDef false "readLoc" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "f") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false (PVar "b") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false (PVar "c") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false (PVar "d") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "a")) (EVar "b")) (EVar "c")) (EVar "d")))) (EIf (EBinOp "==" (EApp (EVar "cursorChar") (EVar "cur")) (ELit (LInt 122))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 1))) (ELit (LInt 0))) (ELit (LInt 1))) (ELit (LInt 0))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltLoc")))))
(DTypeSig false "readEvId" (TyFun (TyCon "SexpCursor") (TyCon "EvId")))
(DFunDef false "readEvId" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "m") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "n") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EvId") (EVar "m")) (EVar "n")))) (EApp (EApp (EVar "EvId") (ELit (LString ""))) (EApp (EVar "readInt") (EVar "cur")))))
(DTypeSig true "readBinderId" (TyFun (TyCon "SexpCursor") (TyCon "BinderId")))
(DFunDef false "readBinderId" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "m") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "n") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "BinderId") (EVar "m")) (EVar "n")))) (EApp (EApp (EVar "BinderId") (ELit (LString ""))) (EApp (EVar "readInt") (EVar "cur")))))
(DTypeSig false "sexpLit" (TyFun (TyCon "Lit") (TyCon "SExp")))
(DFunDef false "sexpLit" ((PCon "LInt" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpInt") (EVar "a0")))))
(DFunDef false "sexpLit" ((PCon "LFloat" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "sexpFloat") (EVar "a0")))))
(DFunDef false "sexpLit" ((PCon "LU64" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpInt") (EVar "a0")) (EApp (EVar "sexpInt") (EVar "a1")))))
(DFunDef false "sexpLit" ((PCon "LI64" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EVar "sexpInt") (EVar "a0")) (EApp (EVar "sexpInt") (EVar "a1")))))
(DFunDef false "sexpLit" ((PCon "LString" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "4"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpLit" ((PCon "LChar" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "5"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpLit" ((PCon "LBool" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "6"))) (EApp (EVar "sexpBool") (EVar "a0")))))
(DFunDef false "sexpLit" ((PCon "LUnit")) (EApp (EVar "SAtom") (ELit (LString "7"))))
(DTypeSig false "sexpTyConOrigin" (TyFun (TyCon "TyConOrigin") (TyCon "SExp")))
(DFunDef false "sexpTyConOrigin" ((PCon "OriginUnresolved")) (EApp (EVar "SAtom") (ELit (LString "0"))))
(DFunDef false "sexpTyConOrigin" ((PCon "OriginBuiltin")) (EApp (EVar "SAtom") (ELit (LString "1"))))
(DFunDef false "sexpTyConOrigin" ((PCon "OriginModule" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DTypeSig false "sexpTy" (TyFun (TyCon "Ty") (TyCon "SExp")))
(DFunDef false "sexpTy" ((PRec "TyCon" ((rf "tyConName" (PVar "a0")) (rf "tyConLoc" (PVar "a1")) (rf "tyConOrigin" (PVar "a2"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a1")) (EApp (EVar "sexpTyConOrigin") (EVar "a2")))))
(DFunDef false "sexpTy" ((PCon "TyVar" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpTy" ((PCon "TyApp" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpTy") (EVar "a0")) (EApp (EVar "sexpTy") (EVar "a1")))))
(DFunDef false "sexpTy" ((PCon "TyFun" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EVar "sexpTy") (EVar "a0")) (EApp (EVar "sexpTy") (EVar "a1")))))
(DFunDef false "sexpTy" ((PCon "TyTuple" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "4"))) (EApp (EApp (EVar "sexpList") (EVar "sexpTy")) (EVar "a0")))))
(DFunDef false "sexpTy" ((PCon "TyEffect" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "5"))) (EApp (EApp (EVar "sexpList") (EVar "sexpEffAtomTy")) (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a1")) (EApp (EVar "sexpTy") (EVar "a2")))))
(DFunDef false "sexpTy" ((PCon "TyConstrained" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "6"))) (EApp (EApp (EVar "sexpList") (EVar "sexpConstraint")) (EVar "a0")) (EApp (EVar "sexpTy") (EVar "a1")))))
(DFunDef false "sexpTy" ((PCon "TyNamed" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "7"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpTy") (EVar "a1")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpEffAtomTy")) (EVar "a2")))))
(DFunDef false "sexpTy" ((PCon "TyQual" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "8"))) (EApp (EVar "sexpTy") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpEffParamTy")) (EVar "a1")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a2")))))
(DFunDef false "sexpTy" ((PCon "TyRow" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "9"))) (EApp (EApp (EVar "sexpList") (EVar "sexpEffAtomTy")) (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a1")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a2")))))
(DFunDef false "sexpTy" ((PCon "TyAuth" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "10"))) (EApp (EApp (EVar "sexpList") (EVar "sexpEffParamTy")) (EVar "a0")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a1")))))
(DTypeSig false "sexpEffAtomTy" (TyFun (TyCon "EffAtomTy") (TyCon "SExp")))
(DFunDef false "sexpEffAtomTy" ((PRec "EffAtomTy" ((rf "eatLabel" (PVar "a0")) (rf "eatOrigin" (PVar "a1")) (rf "eatParam" (PVar "a2")) (rf "eatLoc" (PVar "a3")) (rf "eatPattern" (PVar "a4"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpTyConOrigin") (EVar "a1")) (EApp (EVar "sexpEffParamTy") (EVar "a2")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a3")) (EApp (EVar "sexpBool") (EVar "a4")))))
(DTypeSig false "sexpEffParamTy" (TyFun (TyCon "EffParamTy") (TyCon "SExp")))
(DFunDef false "sexpEffParamTy" ((PCon "EPTop")) (EApp (EVar "SAtom") (ELit (LString "0"))))
(DFunDef false "sexpEffParamTy" ((PCon "EPLit" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpEffParamTy" ((PCon "EPName" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpEffParamTy" ((PCon "EPSet" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a0")))))
(DFunDef false "sexpEffParamTy" ((PCon "EPProduct" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "4"))) (EApp (EApp (EVar "sexpList") (EApp (EApp (EVar "sexpPair") (EVar "sexpString")) (EVar "sexpEffParamTy"))) (EVar "a0")))))
(DTypeSig false "sexpConstraint" (TyFun (TyCon "Constraint") (TyCon "SExp")))
(DFunDef false "sexpConstraint" ((PRec "Constraint" ((rf "constraintHead" (PVar "a0")) (rf "constraintArgs" (PVar "a1")) (rf "constraintOrigin" (PVar "a2"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpTy")) (EVar "a1")) (EApp (EVar "sexpTyConOrigin") (EVar "a2")))))
(DTypeSig false "sexpKindAnn" (TyFun (TyCon "KindAnn") (TyCon "SExp")))
(DFunDef false "sexpKindAnn" ((PCon "KindType")) (EApp (EVar "SAtom") (ELit (LString "0"))))
(DFunDef false "sexpKindAnn" ((PCon "KindEffect")) (EApp (EVar "SAtom") (ELit (LString "1"))))
(DFunDef false "sexpKindAnn" ((PCon "KindAuthority" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpTyConOrigin") (EVar "a1")) (EApp (EVar "sexpBool") (EVar "a2")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a3")))))
(DFunDef false "sexpKindAnn" ((PCon "KindArrow" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EVar "sexpKindAnn") (EVar "a0")) (EApp (EVar "sexpKindAnn") (EVar "a1")))))
(DTypeSig false "sexpRoute" (TyFun (TyCon "Route") (TyCon "SExp")))
(DFunDef false "sexpRoute" ((PCon "RNone")) (EApp (EVar "SAtom") (ELit (LString "0"))))
(DFunDef false "sexpRoute" ((PCon "RKey" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpRoute")) (EVar "a1")) (EApp (EApp (EVar "sexpList") (EVar "sexpRoute")) (EVar "a2")))))
(DFunDef false "sexpRoute" ((PCon "RDict" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpRoute" ((PCon "RDictFwd" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpRoute" ((PCon "RLocal" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "4"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpRoute")) (EVar "a1")))))
(DFunDef false "sexpRoute" ((PCon "RScalar" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "5"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpRoute" ((PCon "RProj" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "6"))) (EApp (EVar "sexpRoute") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpInt")) (EVar "a1")))))
(DTypeSig false "sexpEvVal" (TyFun (TyCon "EvVal") (TyCon "SExp")))
(DFunDef false "sexpEvVal" ((PCon "EvOne" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpRoute") (EVar "a0")))))
(DFunDef false "sexpEvVal" ((PCon "EvMany" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EApp (EVar "sexpList") (EVar "sexpRoute")) (EVar "a0")))))
(DFunDef false "sexpEvVal" ((PCon "EvMethod" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3") (PVar "a4"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpInt") (EVar "a1")) (EApp (EVar "sexpRoute") (EVar "a2")) (EApp (EApp (EVar "sexpList") (EVar "sexpRoute")) (EVar "a3")) (EApp (EApp (EVar "sexpList") (EVar "sexpRoute")) (EVar "a4")))))
(DFunDef false "sexpEvVal" ((PCon "EvLit" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EApp (EVar "sexpOpt") (EVar "sexpFloat")) (EVar "a0")) (EApp (EVar "sexpRoute") (EVar "a1")))))
(DFunDef false "sexpEvVal" ((PCon "EvHead" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "4"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DTypeSig false "sexpEvEntry" (TyFun (TyCon "EvEntry") (TyCon "SExp")))
(DFunDef false "sexpEvEntry" ((PCon "EvEntry" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpEvId") (EVar "a0")) (EApp (EVar "sexpEvVal") (EVar "a1")))))
(DTypeSig false "sexpAddr" (TyFun (TyCon "Addr") (TyCon "SExp")))
(DFunDef false "sexpAddr" ((PCon "ALocal" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpInt") (EVar "a0")) (EApp (EVar "sexpInt") (EVar "a1")))))
(DFunDef false "sexpAddr" ((PCon "AGlobal")) (EApp (EVar "SAtom") (ELit (LString "1"))))
(DTypeSig false "sexpPat" (TyFun (TyCon "Pat") (TyCon "SExp")))
(DFunDef false "sexpPat" ((PCon "PVar" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpLoc") (EVar "a1")) (EApp (EVar "sexpBinderId") (EVar "a2")))))
(DFunDef false "sexpPat" ((PCon "PWild")) (EApp (EVar "SAtom") (ELit (LString "1"))))
(DFunDef false "sexpPat" ((PCon "PLit" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpLit") (EVar "a0")))))
(DFunDef false "sexpPat" ((PCon "PCon" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpPat")) (EVar "a1")))))
(DFunDef false "sexpPat" ((PCon "PCons" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "4"))) (EApp (EVar "sexpPat") (EVar "a0")) (EApp (EVar "sexpPat") (EVar "a1")))))
(DFunDef false "sexpPat" ((PCon "PTuple" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "5"))) (EApp (EApp (EVar "sexpList") (EVar "sexpPat")) (EVar "a0")))))
(DFunDef false "sexpPat" ((PCon "PList" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "6"))) (EApp (EApp (EVar "sexpList") (EVar "sexpPat")) (EVar "a0")))))
(DFunDef false "sexpPat" ((PCon "PAs" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "7"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpLoc") (EVar "a1")) (EApp (EVar "sexpBinderId") (EVar "a2")) (EApp (EVar "sexpPat") (EVar "a3")))))
(DFunDef false "sexpPat" ((PCon "PRng" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "8"))) (EApp (EVar "sexpLit") (EVar "a0")) (EApp (EVar "sexpLit") (EVar "a1")) (EApp (EVar "sexpBool") (EVar "a2")))))
(DFunDef false "sexpPat" ((PCon "PRec" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "9"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpRecPatField")) (EVar "a1")) (EApp (EVar "sexpBool") (EVar "a2")))))
(DTypeSig false "sexpRecPatField" (TyFun (TyCon "RecPatField") (TyCon "SExp")))
(DFunDef false "sexpRecPatField" ((PCon "RecPatField" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpLoc") (EVar "a1")) (EApp (EVar "sexpBinderId") (EVar "a2")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpPat")) (EVar "a3")))))
(DTypeSig false "sexpGuard" (TyFun (TyCon "Guard") (TyCon "SExp")))
(DFunDef false "sexpGuard" ((PCon "GBool" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpExpr") (EVar "a0")))))
(DFunDef false "sexpGuard" ((PCon "GBind" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "sexpPat") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DTypeSig false "sexpArm" (TyFun (TyCon "Arm") (TyCon "SExp")))
(DFunDef false "sexpArm" ((PCon "Arm" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpPat") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpGuard")) (EVar "a1")) (EApp (EVar "sexpExpr") (EVar "a2")))))
(DTypeSig false "sexpDoStmt" (TyFun (TyCon "DoStmt") (TyCon "SExp")))
(DFunDef false "sexpDoStmt" ((PCon "DoExpr" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpExpr") (EVar "a0")))))
(DFunDef false "sexpDoStmt" ((PCon "DoBind" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "sexpPat") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DFunDef false "sexpDoStmt" ((PCon "DoLet" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3") (PVar "a4"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpBool") (EVar "a1")) (EApp (EVar "sexpPat") (EVar "a2")) (EApp (EVar "sexpExpr") (EVar "a3")) (EApp (EVar "sexpLoc") (EVar "a4")))))
(DFunDef false "sexpDoStmt" ((PCon "DoAssign" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DFunDef false "sexpDoStmt" ((PCon "DoFieldAssign" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "4"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a1")) (EApp (EVar "sexpExpr") (EVar "a2")))))
(DTypeSig false "sexpInterpPart" (TyFun (TyCon "InterpPart") (TyCon "SExp")))
(DFunDef false "sexpInterpPart" ((PCon "InterpStr" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpInterpPart" ((PCon "InterpExpr" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "sexpExpr") (EVar "a0")))))
(DTypeSig false "sexpGuardArm" (TyFun (TyCon "GuardArm") (TyCon "SExp")))
(DFunDef false "sexpGuardArm" ((PCon "GuardArm" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EApp (EVar "sexpList") (EVar "sexpGuard")) (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DTypeSig false "sexpFieldAssign" (TyFun (TyCon "FieldAssign") (TyCon "SExp")))
(DFunDef false "sexpFieldAssign" ((PCon "FieldAssign" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DTypeSig false "sexpSection" (TyFun (TyCon "Section") (TyCon "SExp")))
(DFunDef false "sexpSection" ((PCon "SecBare" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpSection" ((PCon "SecRight" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DFunDef false "sexpSection" ((PCon "SecLeft" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")))))
(DTypeSig false "sexpFunClause" (TyFun (TyCon "FunClause") (TyCon "SExp")))
(DFunDef false "sexpFunClause" ((PCon "FunClause" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EApp (EVar "sexpList") (EVar "sexpPat")) (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DTypeSig false "sexpLetBind" (TyFun (TyCon "LetBind") (TyCon "SExp")))
(DFunDef false "sexpLetBind" ((PCon "LetBind" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpFunClause")) (EVar "a1")) (EApp (EVar "sexpLoc") (EVar "a2")) (EApp (EVar "sexpBinderId") (EVar "a3")))))
(DTypeSig false "sexpExpr" (TyFun (TyCon "Expr") (TyCon "SExp")))
(DFunDef false "sexpExpr" ((PCon "ELit" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpLit") (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "EVar" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "EApp" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "ELam" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EApp (EVar "sexpList") (EVar "sexpPat")) (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "ELet" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3") (PVar "a4"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "4"))) (EApp (EVar "sexpLoc") (EVar "a0")) (EApp (EVar "sexpBool") (EVar "a1")) (EApp (EVar "sexpPat") (EVar "a2")) (EApp (EVar "sexpExpr") (EVar "a3")) (EApp (EVar "sexpExpr") (EVar "a4")))))
(DFunDef false "sexpExpr" ((PCon "EMatch" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "5"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpArm")) (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "EIf" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "6"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")) (EApp (EVar "sexpExpr") (EVar "a2")))))
(DFunDef false "sexpExpr" ((PCon "EBinOp" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "7"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")) (EApp (EVar "sexpExpr") (EVar "a2")) (EApp (EVar "sexpEvId") (EVar "a3")))))
(DFunDef false "sexpExpr" ((PCon "EUnOp" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "8"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")) (EApp (EVar "sexpEvId") (EVar "a2")))))
(DFunDef false "sexpExpr" ((PCon "EInfix" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "9"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")) (EApp (EVar "sexpExpr") (EVar "a2")))))
(DFunDef false "sexpExpr" ((PCon "EFieldAccess" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "10"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EVar "sexpEvId") (EVar "a2")))))
(DFunDef false "sexpExpr" ((PCon "ETuple" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "11"))) (EApp (EApp (EVar "sexpList") (EVar "sexpExpr")) (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "EListLit" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "12"))) (EApp (EApp (EVar "sexpList") (EVar "sexpExpr")) (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "EArrayLit" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "13"))) (EApp (EApp (EVar "sexpList") (EVar "sexpExpr")) (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "ERangeList" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "14"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")) (EApp (EVar "sexpBool") (EVar "a2")))))
(DFunDef false "sexpExpr" ((PCon "ERangeArray" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "15"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")) (EApp (EVar "sexpBool") (EVar "a2")))))
(DFunDef false "sexpExpr" ((PCon "ESlice" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "16"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")) (EApp (EVar "sexpExpr") (EVar "a2")) (EApp (EVar "sexpBool") (EVar "a3")))))
(DFunDef false "sexpExpr" ((PCon "ELetGroup" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "17"))) (EApp (EApp (EVar "sexpList") (EVar "sexpLetBind")) (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "ESection" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "18"))) (EApp (EVar "sexpSection") (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "EIndex" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "19"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "EAnnot" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "20"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EVar "sexpTy") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "EHeadAnnot" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "21"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EVar "sexpTy") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "EBlock" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "22"))) (EApp (EApp (EVar "sexpList") (EVar "sexpDoStmt")) (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "EDo" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "23"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpDoStmt")) (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "EStringInterp" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "24"))) (EApp (EApp (EVar "sexpList") (EVar "sexpInterpPart")) (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "EGuards" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "25"))) (EApp (EApp (EVar "sexpList") (EVar "sexpGuardArm")) (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "ERecordCreate" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "26"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpFieldAssign")) (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "ERecordUpdate" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "27"))) (EApp (EVar "sexpExpr") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpFieldAssign")) (EVar "a1")) (EApp (EVar "sexpEvId") (EVar "a2")))))
(DFunDef false "sexpExpr" ((PCon "EVariantUpdate" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "28"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")) (EApp (EApp (EVar "sexpList") (EVar "sexpFieldAssign")) (EVar "a2")))))
(DFunDef false "sexpExpr" ((PCon "EMapLit" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "29"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EApp (EApp (EVar "sexpPair") (EVar "sexpExpr")) (EVar "sexpExpr"))) (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "ESetLit" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "30"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpExpr")) (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "EAsPat" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "31"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "EMethodRef" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "32"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "EDictApp" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "33"))) (EApp (EVar "sexpString") (EVar "a0")))))
(DFunDef false "sexpExpr" ((PCon "EVarAt" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "34"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpAddr") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "EVarId" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "35"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpInt") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "EMethodAt" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "36"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EVar "sexpEvId") (EVar "a2")))))
(DFunDef false "sexpExpr" ((PCon "EDictAt" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "37"))) (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpEvId") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "ELoc" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "38"))) (EApp (EVar "sexpLoc") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "EDoOrigin" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "39"))) (EApp (EVar "sexpLoc") (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DFunDef false "sexpExpr" ((PCon "ENumLit" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "40"))) (EApp (EVar "sexpInt") (EVar "a0")) (EApp (EVar "sexpEvId") (EVar "a1")) (EApp (EVar "sexpString") (EVar "a2")))))
(DFunDef false "sexpExpr" ((PCon "EWideLit" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "41"))) (EApp (EVar "sexpInt") (EVar "a0")) (EApp (EVar "sexpInt") (EVar "a1")) (EApp (EVar "sexpEvId") (EVar "a2")) (EApp (EVar "sexpString") (EVar "a3")))))
(DTypeSig false "sexpUseMember" (TyFun (TyCon "UseMember") (TyCon "SExp")))
(DFunDef false "sexpUseMember" ((PCon "UseMember" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpBool") (EVar "a1")) (EApp (EVar "sexpLoc") (EVar "a2")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpString")) (EVar "a3")))))
(DTypeSig false "sexpUsePath" (TyFun (TyCon "UsePath") (TyCon "SExp")))
(DFunDef false "sexpUsePath" ((PCon "UseName" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a0")))))
(DFunDef false "sexpUsePath" ((PCon "UseGroup" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpUseMember")) (EVar "a1")))))
(DFunDef false "sexpUsePath" ((PCon "UseWild" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a0")))))
(DFunDef false "sexpUsePath" ((PCon "UseAlias" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")))))
(DTypeSig false "sexpPropParam" (TyFun (TyCon "PropParam") (TyCon "SExp")))
(DFunDef false "sexpPropParam" ((PCon "PropParam" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpLoc") (EVar "a1")) (EApp (EVar "sexpTy") (EVar "a2")))))
(DTypeSig false "sexpMethodDefault" (TyFun (TyCon "MethodDefault") (TyCon "SExp")))
(DFunDef false "sexpMethodDefault" ((PCon "MethodDefault" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EApp (EVar "sexpList") (EVar "sexpPat")) (EVar "a0")) (EApp (EVar "sexpExpr") (EVar "a1")))))
(DTypeSig false "sexpIfaceMethod" (TyFun (TyCon "IfaceMethod") (TyCon "SExp")))
(DFunDef false "sexpIfaceMethod" ((PCon "IfaceMethod" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpTy") (EVar "a1")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpMethodDefault")) (EVar "a2")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a3")))))
(DTypeSig false "sexpSuper" (TyFun (TyCon "Super") (TyCon "SExp")))
(DFunDef false "sexpSuper" ((PRec "Super" ((rf "superHead" (PVar "a0")) (rf "superParams" (PVar "a1")) (rf "superOrigin" (PVar "a2"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a1")) (EApp (EVar "sexpTyConOrigin") (EVar "a2")))))
(DTypeSig false "sexpRequire" (TyFun (TyCon "Require") (TyCon "SExp")))
(DFunDef false "sexpRequire" ((PRec "Require" ((rf "requireHead" (PVar "a0")) (rf "requireArgs" (PVar "a1")) (rf "requireOrigin" (PVar "a2"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpTy")) (EVar "a1")) (EApp (EVar "sexpTyConOrigin") (EVar "a2")))))
(DTypeSig false "sexpImplMethod" (TyFun (TyCon "ImplMethod") (TyCon "SExp")))
(DFunDef false "sexpImplMethod" ((PCon "ImplMethod" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpPat")) (EVar "a1")) (EApp (EVar "sexpExpr") (EVar "a2")))))
(DTypeSig false "sexpDataVis" (TyFun (TyCon "DataVis") (TyCon "SExp")))
(DFunDef false "sexpDataVis" ((PCon "VisPrivate")) (EApp (EVar "SAtom") (ELit (LString "0"))))
(DFunDef false "sexpDataVis" ((PCon "VisAbstract")) (EApp (EVar "SAtom") (ELit (LString "1"))))
(DFunDef false "sexpDataVis" ((PCon "VisPublic")) (EApp (EVar "SAtom") (ELit (LString "2"))))
(DTypeSig false "sexpField" (TyFun (TyCon "Field") (TyCon "SExp")))
(DFunDef false "sexpField" ((PCon "Field" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpTy") (EVar "a1")))))
(DTypeSig false "sexpConPayload" (TyFun (TyCon "ConPayload") (TyCon "SExp")))
(DFunDef false "sexpConPayload" ((PCon "ConPos" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EApp (EVar "sexpList") (EVar "sexpTy")) (EVar "a0")))))
(DFunDef false "sexpConPayload" ((PCon "ConNamed" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EApp (EVar "sexpList") (EVar "sexpField")) (EVar "a0")) (EApp (EVar "sexpBool") (EVar "a1")))))
(DTypeSig false "sexpVariant" (TyFun (TyCon "Variant") (TyCon "SExp")))
(DFunDef false "sexpVariant" ((PCon "Variant" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpConPayload") (EVar "a1")))))
(DTypeSig false "sexpAttr" (TyFun (TyCon "Attr") (TyCon "SExp")))
(DFunDef false "sexpAttr" ((PCon "AttrDeprecated" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EApp (EVar "sexpOpt") (EVar "sexpString")) (EVar "a0")))))
(DFunDef false "sexpAttr" ((PCon "AttrInline")) (EApp (EVar "SAtom") (ELit (LString "1"))))
(DFunDef false "sexpAttr" ((PCon "AttrMustUse")) (EApp (EVar "SAtom") (ELit (LString "2"))))
(DFunDef false "sexpAttr" ((PCon "AttrNoInline")) (EApp (EVar "SAtom") (ELit (LString "3"))))
(DTypeSig false "sexpDeriveRef" (TyFun (TyCon "DeriveRef") (TyCon "SExp")))
(DFunDef false "sexpDeriveRef" ((PCon "DeriveRef" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a1")))))
(DTypeSig false "sexpExternDecl" (TyFun (TyCon "ExternDecl") (TyCon "SExp")))
(DFunDef false "sexpExternDecl" ((PRec "ExternDecl" ((rf "edPub" (PVar "a0")) (rf "edName" (PVar "a1")) (rf "edTy" (PVar "a2")) (rf "edLoc" (PVar "a3")) (rf "edBinds" (PVar "a4"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EVar "sexpTy") (EVar "a2")) (EApp (EVar "sexpLoc") (EVar "a3")) (EApp (EApp (EVar "sexpList") (EVar "sexpExternBind")) (EVar "a4")))))
(DTypeSig false "sexpExternBind" (TyFun (TyCon "ExternBind") (TyCon "SExp")))
(DFunDef false "sexpExternBind" ((PRec "ExternBind" ((rf "ebHost" (PVar "a0")) (rf "ebSymbol" (PVar "a1")) (rf "ebLoc" (PVar "a2"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpString") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EVar "sexpLoc") (EVar "a2")))))
(DTypeSig false "sexpDecl" (TyFun (TyCon "Decl") (TyCon "SExp")))
(DFunDef false "sexpDecl" ((PCon "DTypeSig" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "0"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EVar "sexpTy") (EVar "a2")) (EApp (EVar "sexpLoc") (EVar "a3")))))
(DFunDef false "sexpDecl" ((PCon "DExtern" (PVar "a0"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "sexpExternDecl") (EVar "a0")))))
(DFunDef false "sexpDecl" ((PCon "DFunDef" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3") (PVar "a4") (PVar "a5"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "2"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EApp (EVar "sexpList") (EVar "sexpPat")) (EVar "a2")) (EApp (EVar "sexpExpr") (EVar "a3")) (EApp (EVar "sexpLoc") (EVar "a4")) (EApp (EVar "sexpBinderId") (EVar "a5")))))
(DFunDef false "sexpDecl" ((PRec "DData" ((rf "dataVis" (PVar "a0")) (rf "dataName" (PVar "a1")) (rf "dataParams" (PVar "a2")) (rf "dataParamKinds" (PVar "a3")) (rf "dataCtors" (PVar "a4")) (rf "dataCtorBinders" (PVar "a5")) (rf "dataDerives" (PVar "a6")) (rf "dataOrigin" (PVar "a7")) (rf "dataExtern" (PVar "a8")) (rf "dataNameLoc" (PVar "a9"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "3"))) (EApp (EVar "sexpDataVis") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a2")) (EApp (EApp (EVar "sexpList") (EApp (EVar "sexpOpt") (EVar "sexpKindAnn"))) (EVar "a3")) (EApp (EApp (EVar "sexpList") (EVar "sexpVariant")) (EVar "a4")) (EApp (EApp (EVar "sexpList") (EApp (EVar "sexpList") (EApp (EApp (EVar "sexpPair") (EVar "sexpString")) (EVar "sexpKindAnn")))) (EVar "a5")) (EApp (EApp (EVar "sexpList") (EVar "sexpDeriveRef")) (EVar "a6")) (EApp (EVar "sexpTyConOrigin") (EVar "a7")) (EApp (EVar "sexpBool") (EVar "a8")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a9")))))
(DFunDef false "sexpDecl" ((PCon "DUse" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "4"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpUsePath") (EVar "a1")) (EApp (EVar "sexpLoc") (EVar "a2")))))
(DFunDef false "sexpDecl" ((PCon "DEffect" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3") (PVar "a4") (PVar "a5"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "5"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpString")) (EVar "a2")) (EApp (EApp (EVar "sexpList") (EApp (EApp (EVar "sexpPair") (EVar "sexpString")) (EVar "sexpString"))) (EVar "a3")) (EApp (EVar "sexpTyConOrigin") (EVar "a4")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a5")))))
(DFunDef false "sexpDecl" ((PCon "DProp" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "6"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EApp (EVar "sexpList") (EVar "sexpPropParam")) (EVar "a2")) (EApp (EVar "sexpExpr") (EVar "a3")))))
(DFunDef false "sexpDecl" ((PCon "DTest" (PVar "a0") (PVar "a1") (PVar "a2"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "7"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EVar "sexpExpr") (EVar "a2")))))
(DFunDef false "sexpDecl" ((PRec "DInterface" ((rf "pub" (PVar "a0")) (rf "def" (PVar "a1")) (rf "name" (PVar "a2")) (rf "typarams" (PVar "a3")) (rf "typaramKinds" (PVar "a4")) (rf "supers" (PVar "a5")) (rf "methods" (PVar "a6")) (rf "ifaceOrigin" (PVar "a7")) (rf "ifaceNameLoc" (PVar "a8"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "8"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpBool") (EVar "a1")) (EApp (EVar "sexpString") (EVar "a2")) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a3")) (EApp (EApp (EVar "sexpList") (EApp (EVar "sexpOpt") (EVar "sexpKindAnn"))) (EVar "a4")) (EApp (EApp (EVar "sexpList") (EVar "sexpSuper")) (EVar "a5")) (EApp (EApp (EVar "sexpList") (EVar "sexpIfaceMethod")) (EVar "a6")) (EApp (EVar "sexpTyConOrigin") (EVar "a7")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a8")))))
(DFunDef false "sexpDecl" ((PRec "DImpl" ((rf "pub" (PVar "a0")) (rf "iface" (PVar "a1")) (rf "tys" (PVar "a2")) (rf "reqs" (PVar "a3")) (rf "methods" (PVar "a4")) (rf "implOrigin" (PVar "a5")) (rf "implIfaceLoc" (PVar "a6"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "9"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EApp (EVar "sexpList") (EVar "sexpTy")) (EVar "a2")) (EApp (EApp (EVar "sexpList") (EVar "sexpRequire")) (EVar "a3")) (EApp (EApp (EVar "sexpList") (EVar "sexpImplMethod")) (EVar "a4")) (EApp (EVar "sexpTyConOrigin") (EVar "a5")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a6")))))
(DFunDef false "sexpDecl" ((PRec "DTypeAlias" ((rf "tyAliasPub" (PVar "a0")) (rf "tyAliasName" (PVar "a1")) (rf "tyAliasParams" (PVar "a2")) (rf "tyAliasParamKinds" (PVar "a3")) (rf "tyAliasRhs" (PVar "a4")) (rf "tyAliasOrigin" (PVar "a5")) (rf "tyAliasNameLoc" (PVar "a6"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "10"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a2")) (EApp (EApp (EVar "sexpList") (EApp (EVar "sexpOpt") (EVar "sexpKindAnn"))) (EVar "a3")) (EApp (EVar "sexpTy") (EVar "a4")) (EApp (EVar "sexpTyConOrigin") (EVar "a5")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a6")))))
(DFunDef false "sexpDecl" ((PRec "DNewtype" ((rf "newtypePub" (PVar "a0")) (rf "newtypeName" (PVar "a1")) (rf "newtypeParams" (PVar "a2")) (rf "newtypeParamKinds" (PVar "a3")) (rf "newtypeCtor" (PVar "a4")) (rf "newtypeCtorBinders" (PVar "a5")) (rf "newtypeFieldTy" (PVar "a6")) (rf "newtypeDerives" (PVar "a7")) (rf "newtypeOrigin" (PVar "a8")) (rf "newtypeNameLoc" (PVar "a9"))) false)) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "11"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EVar "sexpString") (EVar "a1")) (EApp (EApp (EVar "sexpList") (EVar "sexpString")) (EVar "a2")) (EApp (EApp (EVar "sexpList") (EApp (EVar "sexpOpt") (EVar "sexpKindAnn"))) (EVar "a3")) (EApp (EVar "sexpString") (EVar "a4")) (EApp (EApp (EVar "sexpList") (EApp (EApp (EVar "sexpPair") (EVar "sexpString")) (EVar "sexpKindAnn"))) (EVar "a5")) (EApp (EVar "sexpTy") (EVar "a6")) (EApp (EApp (EVar "sexpList") (EVar "sexpDeriveRef")) (EVar "a7")) (EApp (EVar "sexpTyConOrigin") (EVar "a8")) (EApp (EApp (EVar "sexpOpt") (EVar "sexpLoc")) (EVar "a9")))))
(DFunDef false "sexpDecl" ((PCon "DLetGroup" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "12"))) (EApp (EVar "sexpBool") (EVar "a0")) (EApp (EApp (EVar "sexpList") (EVar "sexpLetBind")) (EVar "a1")))))
(DFunDef false "sexpDecl" ((PCon "DAttrib" (PVar "a0") (PVar "a1"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "13"))) (EApp (EApp (EVar "sexpList") (EVar "sexpAttr")) (EVar "a0")) (EApp (EVar "sexpDecl") (EVar "a1")))))
(DTypeSig false "dfltLoc" (TyCon "Loc"))
(DFunDef false "dfltLoc" () (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 1))) (ELit (LInt 0))) (ELit (LInt 1))) (ELit (LInt 0))))
(DTypeSig false "dfltLit" (TyCon "Lit"))
(DFunDef false "dfltLit" () (EVar "LUnit"))
(DTypeSig false "dfltTyConOrigin" (TyCon "TyConOrigin"))
(DFunDef false "dfltTyConOrigin" () (EVar "OriginUnresolved"))
(DTypeSig false "dfltTy" (TyCon "Ty"))
(DFunDef false "dfltTy" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString ""))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "dfltTyConOrigin")))))
(DTypeSig false "dfltEffParamTy" (TyCon "EffParamTy"))
(DFunDef false "dfltEffParamTy" () (EVar "EPTop"))
(DTypeSig false "dfltKindAnn" (TyCon "KindAnn"))
(DFunDef false "dfltKindAnn" () (EVar "KindType"))
(DTypeSig false "dfltRoute" (TyCon "Route"))
(DFunDef false "dfltRoute" () (EVar "RNone"))
(DTypeSig false "dfltEvVal" (TyCon "EvVal"))
(DFunDef false "dfltEvVal" () (EApp (EVar "EvOne") (EVar "dfltRoute")))
(DTypeSig false "dfltAddr" (TyCon "Addr"))
(DFunDef false "dfltAddr" () (EVar "AGlobal"))
(DTypeSig false "dfltPat" (TyCon "Pat"))
(DFunDef false "dfltPat" () (EVar "PWild"))
(DTypeSig false "dfltGuard" (TyCon "Guard"))
(DFunDef false "dfltGuard" () (EApp (EVar "GBool") (EVar "dfltExpr")))
(DTypeSig false "dfltDoStmt" (TyCon "DoStmt"))
(DFunDef false "dfltDoStmt" () (EApp (EVar "DoExpr") (EVar "dfltExpr")))
(DTypeSig false "dfltInterpPart" (TyCon "InterpPart"))
(DFunDef false "dfltInterpPart" () (EApp (EVar "InterpStr") (ELit (LString ""))))
(DTypeSig false "dfltSection" (TyCon "Section"))
(DFunDef false "dfltSection" () (EApp (EVar "SecBare") (ELit (LString ""))))
(DTypeSig false "dfltExpr" (TyCon "Expr"))
(DFunDef false "dfltExpr" () (EApp (EVar "ELit") (EVar "dfltLit")))
(DTypeSig false "dfltUsePath" (TyCon "UsePath"))
(DFunDef false "dfltUsePath" () (EApp (EVar "UseName") (EListLit)))
(DTypeSig false "dfltDataVis" (TyCon "DataVis"))
(DFunDef false "dfltDataVis" () (EVar "VisPrivate"))
(DTypeSig false "dfltConPayload" (TyCon "ConPayload"))
(DFunDef false "dfltConPayload" () (EApp (EVar "ConPos") (EListLit)))
(DTypeSig false "dfltAttr" (TyCon "Attr"))
(DFunDef false "dfltAttr" () (EVar "AttrInline"))
(DTypeSig false "dfltDecl" (TyCon "Decl"))
(DFunDef false "dfltDecl" () (EApp (EApp (EApp (EApp (EVar "DTypeSig") (EVar "False")) (ELit (LString ""))) (EVar "dfltTy")) (EVar "dfltLoc")))
(DTypeSig false "readLit" (TyFun (TyCon "SexpCursor") (TyCon "Lit")))
(DFunDef false "readLit" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readLitTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readLitBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readLitBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Lit"))))
(DFunDef false "readLitBare" ((PLit (LInt 7)) PWild) (EVar "LUnit"))
(DFunDef false "readLitBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltLit")))
(DTypeSig false "readLitTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Lit"))))
(DFunDef false "readLitTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readInt") (EVar "cur"))) (DoExpr (EApp (EVar "LInt") (EVar "a0")))))
(DFunDef false "readLitTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readFloat") (EVar "cur"))) (DoExpr (EApp (EVar "LFloat") (EVar "a0")))))
(DFunDef false "readLitTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readInt") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "LU64") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readLitTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readInt") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "LI64") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readLitTagged" ((PLit (LInt 4)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "LString") (EVar "a0")))))
(DFunDef false "readLitTagged" ((PLit (LInt 5)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "LChar") (EVar "a0")))))
(DFunDef false "readLitTagged" ((PLit (LInt 6)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoExpr (EApp (EVar "LBool") (EVar "a0")))))
(DFunDef false "readLitTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltLit")))
(DTypeSig false "readTyConOrigin" (TyFun (TyCon "SexpCursor") (TyCon "TyConOrigin")))
(DFunDef false "readTyConOrigin" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readTyConOriginTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readTyConOriginBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readTyConOriginBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "TyConOrigin"))))
(DFunDef false "readTyConOriginBare" ((PLit (LInt 0)) PWild) (EVar "OriginUnresolved"))
(DFunDef false "readTyConOriginBare" ((PLit (LInt 1)) PWild) (EVar "OriginBuiltin"))
(DFunDef false "readTyConOriginBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltTyConOrigin")))
(DTypeSig false "readTyConOriginTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "TyConOrigin"))))
(DFunDef false "readTyConOriginTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "OriginModule") (EVar "a0")))))
(DFunDef false "readTyConOriginTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltTyConOrigin")))
(DTypeSig false "readTy" (TyFun (TyCon "SexpCursor") (TyCon "Ty")))
(DFunDef false "readTy" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readTyTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readTyBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readTyBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Ty"))))
(DFunDef false "readTyBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltTy")))
(DTypeSig false "readTyTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Ty"))))
(DFunDef false "readTyTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoExpr (ERecordCreate "TyCon" ((fa "tyConName" (EVar "a0")) (fa "tyConLoc" (EVar "a1")) (fa "tyConOrigin" (EVar "a2")))))))
(DFunDef false "readTyTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "TyVar") (EVar "a0")))))
(DFunDef false "readTyTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readTy") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "TyApp") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readTyTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readTy") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "TyFun") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readTyTagged" ((PLit (LInt 4)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readTy")) (EVar "cur"))) (DoExpr (EApp (EVar "TyTuple") (EVar "a0")))))
(DFunDef false "readTyTagged" ((PLit (LInt 5)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readEffAtomTy")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readTy") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "TyEffect") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readTyTagged" ((PLit (LInt 6)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readConstraint")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readTy") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "TyConstrained") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readTyTagged" ((PLit (LInt 7)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "readOpt") (EVar "readEffAtomTy")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "TyNamed") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readTyTagged" ((PLit (LInt 8)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readEffParamTy")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "TyQual") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readTyTagged" ((PLit (LInt 9)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readEffAtomTy")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "TyRow") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readTyTagged" ((PLit (LInt 10)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readEffParamTy")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "TyAuth") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readTyTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltTy")))
(DTypeSig false "readEffAtomTy" (TyFun (TyCon "SexpCursor") (TyCon "EffAtomTy")))
(DFunDef false "readEffAtomTy" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readEffParamTy") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ERecordCreate "EffAtomTy" ((fa "eatLabel" (EVar "a0")) (fa "eatOrigin" (EVar "a1")) (fa "eatParam" (EVar "a2")) (fa "eatLoc" (EVar "a3")) (fa "eatPattern" (EVar "a4")))))))
(DTypeSig false "readEffParamTy" (TyFun (TyCon "SexpCursor") (TyCon "EffParamTy")))
(DFunDef false "readEffParamTy" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readEffParamTyTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readEffParamTyBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readEffParamTyBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "EffParamTy"))))
(DFunDef false "readEffParamTyBare" ((PLit (LInt 0)) PWild) (EVar "EPTop"))
(DFunDef false "readEffParamTyBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltEffParamTy")))
(DTypeSig false "readEffParamTyTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "EffParamTy"))))
(DFunDef false "readEffParamTyTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "EPLit") (EVar "a0")))))
(DFunDef false "readEffParamTyTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "EPName") (EVar "a0")))))
(DFunDef false "readEffParamTyTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoExpr (EApp (EVar "EPSet") (EVar "a0")))))
(DFunDef false "readEffParamTyTagged" ((PLit (LInt 4)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EApp (EApp (EVar "readPair") (EVar "readString")) (EVar "readEffParamTy"))) (EVar "cur"))) (DoExpr (EApp (EVar "EPProduct") (EVar "a0")))))
(DFunDef false "readEffParamTyTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltEffParamTy")))
(DTypeSig false "readConstraint" (TyFun (TyCon "SexpCursor") (TyCon "Constraint")))
(DFunDef false "readConstraint" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readTy")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ERecordCreate "Constraint" ((fa "constraintHead" (EVar "a0")) (fa "constraintArgs" (EVar "a1")) (fa "constraintOrigin" (EVar "a2")))))))
(DTypeSig false "readKindAnn" (TyFun (TyCon "SexpCursor") (TyCon "KindAnn")))
(DFunDef false "readKindAnn" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readKindAnnTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readKindAnnBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readKindAnnBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "KindAnn"))))
(DFunDef false "readKindAnnBare" ((PLit (LInt 0)) PWild) (EVar "KindType"))
(DFunDef false "readKindAnnBare" ((PLit (LInt 1)) PWild) (EVar "KindEffect"))
(DFunDef false "readKindAnnBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltKindAnn")))
(DTypeSig false "readKindAnnTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "KindAnn"))))
(DFunDef false "readKindAnnTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "KindAuthority") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DFunDef false "readKindAnnTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readKindAnn") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readKindAnn") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "KindArrow") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readKindAnnTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltKindAnn")))
(DTypeSig false "readRoute" (TyFun (TyCon "SexpCursor") (TyCon "Route")))
(DFunDef false "readRoute" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readRouteTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readRouteBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readRouteBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Route"))))
(DFunDef false "readRouteBare" ((PLit (LInt 0)) PWild) (EVar "RNone"))
(DFunDef false "readRouteBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltRoute")))
(DTypeSig false "readRouteTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Route"))))
(DFunDef false "readRouteTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readRoute")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "cursorList") (EVar "readRoute")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "RKey") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readRouteTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "RDict") (EVar "a0")))))
(DFunDef false "readRouteTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "RDictFwd") (EVar "a0")))))
(DFunDef false "readRouteTagged" ((PLit (LInt 4)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readRoute")) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "RLocal") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readRouteTagged" ((PLit (LInt 5)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "RScalar") (EVar "a0")))))
(DFunDef false "readRouteTagged" ((PLit (LInt 6)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readRoute") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readInt")) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "RProj") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readRouteTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltRoute")))
(DTypeSig false "readEvVal" (TyFun (TyCon "SexpCursor") (TyCon "EvVal")))
(DFunDef false "readEvVal" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readEvValTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readEvValBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readEvValBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "EvVal"))))
(DFunDef false "readEvValBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltEvVal")))
(DTypeSig false "readEvValTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "EvVal"))))
(DFunDef false "readEvValTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readRoute") (EVar "cur"))) (DoExpr (EApp (EVar "EvOne") (EVar "a0")))))
(DFunDef false "readEvValTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readRoute")) (EVar "cur"))) (DoExpr (EApp (EVar "EvMany") (EVar "a0")))))
(DFunDef false "readEvValTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readRoute") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "cursorList") (EVar "readRoute")) (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EApp (EVar "cursorList") (EVar "readRoute")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "EvMethod") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")) (EVar "a4")))))
(DFunDef false "readEvValTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "readOpt") (EVar "readFloat")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readRoute") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EvLit") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readEvValTagged" ((PLit (LInt 4)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "EvHead") (EVar "a0")))))
(DFunDef false "readEvValTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltEvVal")))
(DTypeSig false "readEvEntry" (TyFun (TyCon "SexpCursor") (TyCon "EvEntry")))
(DFunDef false "readEvEntry" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readEvId") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readEvVal") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EvEntry") (EVar "a0")) (EVar "a1")))))
(DTypeSig false "readAddr" (TyFun (TyCon "SexpCursor") (TyCon "Addr")))
(DFunDef false "readAddr" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readAddrTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readAddrBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readAddrBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Addr"))))
(DFunDef false "readAddrBare" ((PLit (LInt 1)) PWild) (EVar "AGlobal"))
(DFunDef false "readAddrBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltAddr")))
(DTypeSig false "readAddrTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Addr"))))
(DFunDef false "readAddrTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readInt") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "ALocal") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readAddrTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltAddr")))
(DTypeSig false "readPat" (TyFun (TyCon "SexpCursor") (TyCon "Pat")))
(DFunDef false "readPat" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readPatTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readPatBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readPatBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Pat"))))
(DFunDef false "readPatBare" ((PLit (LInt 1)) PWild) (EVar "PWild"))
(DFunDef false "readPatBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltPat")))
(DTypeSig false "readPatTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Pat"))))
(DFunDef false "readPatTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readBinderId") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "PVar") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readPatTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readLit") (EVar "cur"))) (DoExpr (EApp (EVar "PLit") (EVar "a0")))))
(DFunDef false "readPatTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readPat")) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "PCon") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readPatTagged" ((PLit (LInt 4)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readPat") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readPat") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "PCons") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readPatTagged" ((PLit (LInt 5)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readPat")) (EVar "cur"))) (DoExpr (EApp (EVar "PTuple") (EVar "a0")))))
(DFunDef false "readPatTagged" ((PLit (LInt 6)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readPat")) (EVar "cur"))) (DoExpr (EApp (EVar "PList") (EVar "a0")))))
(DFunDef false "readPatTagged" ((PLit (LInt 7)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readBinderId") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readPat") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "PAs") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DFunDef false "readPatTagged" ((PLit (LInt 8)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readLit") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readLit") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readBool") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "PRng") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readPatTagged" ((PLit (LInt 9)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readRecPatField")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readBool") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "PRec") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readPatTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltPat")))
(DTypeSig false "readRecPatField" (TyFun (TyCon "SexpCursor") (TyCon "RecPatField")))
(DFunDef false "readRecPatField" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readBinderId") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "readOpt") (EVar "readPat")) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "RecPatField") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DTypeSig false "readGuard" (TyFun (TyCon "SexpCursor") (TyCon "Guard")))
(DFunDef false "readGuard" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readGuardTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readGuardBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readGuardBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Guard"))))
(DFunDef false "readGuardBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltGuard")))
(DTypeSig false "readGuardTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Guard"))))
(DFunDef false "readGuardTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EVar "GBool") (EVar "a0")))))
(DFunDef false "readGuardTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readPat") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "GBind") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readGuardTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltGuard")))
(DTypeSig false "readArm" (TyFun (TyCon "SexpCursor") (TyCon "Arm")))
(DFunDef false "readArm" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readPat") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readGuard")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DTypeSig false "readDoStmt" (TyFun (TyCon "SexpCursor") (TyCon "DoStmt")))
(DFunDef false "readDoStmt" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readDoStmtTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readDoStmtBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readDoStmtBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "DoStmt"))))
(DFunDef false "readDoStmtBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltDoStmt")))
(DTypeSig false "readDoStmtTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "DoStmt"))))
(DFunDef false "readDoStmtTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EVar "DoExpr") (EVar "a0")))))
(DFunDef false "readDoStmtTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readPat") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "DoBind") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readDoStmtTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readPat") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EVar "readLoc") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")) (EVar "a4")))))
(DFunDef false "readDoStmtTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "DoAssign") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readDoStmtTagged" ((PLit (LInt 4)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readDoStmtTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltDoStmt")))
(DTypeSig false "readInterpPart" (TyFun (TyCon "SexpCursor") (TyCon "InterpPart")))
(DFunDef false "readInterpPart" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readInterpPartTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readInterpPartBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readInterpPartBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "InterpPart"))))
(DFunDef false "readInterpPartBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltInterpPart")))
(DTypeSig false "readInterpPartTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "InterpPart"))))
(DFunDef false "readInterpPartTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "InterpStr") (EVar "a0")))))
(DFunDef false "readInterpPartTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EVar "InterpExpr") (EVar "a0")))))
(DFunDef false "readInterpPartTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltInterpPart")))
(DTypeSig false "readGuardArm" (TyFun (TyCon "SexpCursor") (TyCon "GuardArm")))
(DFunDef false "readGuardArm" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readGuard")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "GuardArm") (EVar "a0")) (EVar "a1")))))
(DTypeSig false "readFieldAssign" (TyFun (TyCon "SexpCursor") (TyCon "FieldAssign")))
(DFunDef false "readFieldAssign" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "FieldAssign") (EVar "a0")) (EVar "a1")))))
(DTypeSig false "readSection" (TyFun (TyCon "SexpCursor") (TyCon "Section")))
(DFunDef false "readSection" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readSectionTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readSectionBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readSectionBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Section"))))
(DFunDef false "readSectionBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltSection")))
(DTypeSig false "readSectionTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Section"))))
(DFunDef false "readSectionTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "SecBare") (EVar "a0")))))
(DFunDef false "readSectionTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "SecRight") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readSectionTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "SecLeft") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readSectionTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltSection")))
(DTypeSig false "readFunClause" (TyFun (TyCon "SexpCursor") (TyCon "FunClause")))
(DFunDef false "readFunClause" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readPat")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "FunClause") (EVar "a0")) (EVar "a1")))))
(DTypeSig false "readLetBind" (TyFun (TyCon "SexpCursor") (TyCon "LetBind")))
(DFunDef false "readLetBind" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readFunClause")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readBinderId") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DTypeSig false "readExpr" (TyFun (TyCon "SexpCursor") (TyCon "Expr")))
(DFunDef false "readExpr" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readExprTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readExprBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readExprBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Expr"))))
(DFunDef false "readExprBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltExpr")))
(DTypeSig false "readExprTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Expr"))))
(DFunDef false "readExprTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readLit") (EVar "cur"))) (DoExpr (EApp (EVar "ELit") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "EVar") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EApp") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readPat")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "ELam") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 4)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readPat") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")) (EVar "a4")))))
(DFunDef false "readExprTagged" ((PLit (LInt 5)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readArm")) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EMatch") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 6)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "EIf") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readExprTagged" ((PLit (LInt 7)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readEvId") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DFunDef false "readExprTagged" ((PLit (LInt 8)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readEvId") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "EUnOp") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readExprTagged" ((PLit (LInt 9)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "EInfix") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readExprTagged" ((PLit (LInt 10)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readEvId") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "EFieldAccess") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readExprTagged" ((PLit (LInt 11)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readExpr")) (EVar "cur"))) (DoExpr (EApp (EVar "ETuple") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 12)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readExpr")) (EVar "cur"))) (DoExpr (EApp (EVar "EListLit") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 13)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readExpr")) (EVar "cur"))) (DoExpr (EApp (EVar "EArrayLit") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 14)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readBool") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "ERangeList") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readExprTagged" ((PLit (LInt 15)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readBool") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "ERangeArray") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readExprTagged" ((PLit (LInt 16)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readBool") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "ESlice") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DFunDef false "readExprTagged" ((PLit (LInt 17)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readLetBind")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "ELetGroup") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 18)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readSection") (EVar "cur"))) (DoExpr (EApp (EVar "ESection") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 19)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EIndex") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 20)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readTy") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EAnnot") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 21)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readTy") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EHeadAnnot") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 22)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readDoStmt")) (EVar "cur"))) (DoExpr (EApp (EVar "EBlock") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 23)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readDoStmt")) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EDo") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 24)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readInterpPart")) (EVar "cur"))) (DoExpr (EApp (EVar "EStringInterp") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 25)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readGuardArm")) (EVar "cur"))) (DoExpr (EApp (EVar "EGuards") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 26)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readFieldAssign")) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "ERecordCreate") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 27)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readFieldAssign")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readEvId") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "ERecordUpdate") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readExprTagged" ((PLit (LInt 28)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "cursorList") (EVar "readFieldAssign")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readExprTagged" ((PLit (LInt 29)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EApp (EApp (EVar "readPair") (EVar "readExpr")) (EVar "readExpr"))) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EMapLit") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 30)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readExpr")) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "ESetLit") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 31)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EAsPat") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 32)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "EMethodRef") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 33)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EVar "EDictApp") (EVar "a0")))))
(DFunDef false "readExprTagged" ((PLit (LInt 34)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readAddr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EVarAt") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 35)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readInt") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EVarId") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 36)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readEvId") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "EMethodAt") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readExprTagged" ((PLit (LInt 37)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readEvId") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EDictAt") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 38)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "ELoc") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 39)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "EDoOrigin") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readExprTagged" ((PLit (LInt 40)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readEvId") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "ENumLit") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readExprTagged" ((PLit (LInt 41)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readInt") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readEvId") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "EWideLit") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DFunDef false "readExprTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltExpr")))
(DTypeSig false "readUseMember" (TyFun (TyCon "SexpCursor") (TyCon "UseMember")))
(DFunDef false "readUseMember" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "readOpt") (EVar "readString")) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DTypeSig false "readUsePath" (TyFun (TyCon "SexpCursor") (TyCon "UsePath")))
(DFunDef false "readUsePath" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readUsePathTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readUsePathBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readUsePathBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "UsePath"))))
(DFunDef false "readUsePathBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltUsePath")))
(DTypeSig false "readUsePathTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "UsePath"))))
(DFunDef false "readUsePathTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoExpr (EApp (EVar "UseName") (EVar "a0")))))
(DFunDef false "readUsePathTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readUseMember")) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "UseGroup") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readUsePathTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoExpr (EApp (EVar "UseWild") (EVar "a0")))))
(DFunDef false "readUsePathTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "UseAlias") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readUsePathTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltUsePath")))
(DTypeSig false "readPropParam" (TyFun (TyCon "SexpCursor") (TyCon "PropParam")))
(DFunDef false "readPropParam" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "PropParam") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DTypeSig false "readMethodDefault" (TyFun (TyCon "SexpCursor") (TyCon "MethodDefault")))
(DFunDef false "readMethodDefault" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readPat")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "MethodDefault") (EVar "a0")) (EVar "a1")))))
(DTypeSig false "readIfaceMethod" (TyFun (TyCon "SexpCursor") (TyCon "IfaceMethod")))
(DFunDef false "readIfaceMethod" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "readOpt") (EVar "readMethodDefault")) (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DTypeSig false "readSuper" (TyFun (TyCon "SexpCursor") (TyCon "Super")))
(DFunDef false "readSuper" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ERecordCreate "Super" ((fa "superHead" (EVar "a0")) (fa "superParams" (EVar "a1")) (fa "superOrigin" (EVar "a2")))))))
(DTypeSig false "readRequire" (TyFun (TyCon "SexpCursor") (TyCon "Require")))
(DFunDef false "readRequire" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readTy")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ERecordCreate "Require" ((fa "requireHead" (EVar "a0")) (fa "requireArgs" (EVar "a1")) (fa "requireOrigin" (EVar "a2")))))))
(DTypeSig false "readImplMethod" (TyFun (TyCon "SexpCursor") (TyCon "ImplMethod")))
(DFunDef false "readImplMethod" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readPat")) (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "ImplMethod") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DTypeSig false "readDataVis" (TyFun (TyCon "SexpCursor") (TyCon "DataVis")))
(DFunDef false "readDataVis" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readDataVisTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readDataVisBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readDataVisBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "DataVis"))))
(DFunDef false "readDataVisBare" ((PLit (LInt 0)) PWild) (EVar "VisPrivate"))
(DFunDef false "readDataVisBare" ((PLit (LInt 1)) PWild) (EVar "VisAbstract"))
(DFunDef false "readDataVisBare" ((PLit (LInt 2)) PWild) (EVar "VisPublic"))
(DFunDef false "readDataVisBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltDataVis")))
(DTypeSig false "readDataVisTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "DataVis"))))
(DFunDef false "readDataVisTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltDataVis")))
(DTypeSig false "readField" (TyFun (TyCon "SexpCursor") (TyCon "Field")))
(DFunDef false "readField" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "Field") (EVar "a0")) (EVar "a1")))))
(DTypeSig false "readConPayload" (TyFun (TyCon "SexpCursor") (TyCon "ConPayload")))
(DFunDef false "readConPayload" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readConPayloadTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readConPayloadBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readConPayloadBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "ConPayload"))))
(DFunDef false "readConPayloadBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltConPayload")))
(DTypeSig false "readConPayloadTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "ConPayload"))))
(DFunDef false "readConPayloadTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readTy")) (EVar "cur"))) (DoExpr (EApp (EVar "ConPos") (EVar "a0")))))
(DFunDef false "readConPayloadTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readField")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readBool") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "ConNamed") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readConPayloadTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltConPayload")))
(DTypeSig false "readVariant" (TyFun (TyCon "SexpCursor") (TyCon "Variant")))
(DFunDef false "readVariant" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readConPayload") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "Variant") (EVar "a0")) (EVar "a1")))))
(DTypeSig false "readAttr" (TyFun (TyCon "SexpCursor") (TyCon "Attr")))
(DFunDef false "readAttr" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readAttrTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readAttrBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readAttrBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Attr"))))
(DFunDef false "readAttrBare" ((PLit (LInt 1)) PWild) (EVar "AttrInline"))
(DFunDef false "readAttrBare" ((PLit (LInt 2)) PWild) (EVar "AttrMustUse"))
(DFunDef false "readAttrBare" ((PLit (LInt 3)) PWild) (EVar "AttrNoInline"))
(DFunDef false "readAttrBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltAttr")))
(DTypeSig false "readAttrTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Attr"))))
(DFunDef false "readAttrTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "readOpt") (EVar "readString")) (EVar "cur"))) (DoExpr (EApp (EVar "AttrDeprecated") (EVar "a0")))))
(DFunDef false "readAttrTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltAttr")))
(DTypeSig false "readDeriveRef" (TyFun (TyCon "SexpCursor") (TyCon "DeriveRef")))
(DFunDef false "readDeriveRef" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "DeriveRef") (EVar "a0")) (EVar "a1")))))
(DTypeSig false "readExternDecl" (TyFun (TyCon "SexpCursor") (TyCon "ExternDecl")))
(DFunDef false "readExternDecl" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EApp (EVar "cursorList") (EVar "readExternBind")) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ERecordCreate "ExternDecl" ((fa "edPub" (EVar "a0")) (fa "edName" (EVar "a1")) (fa "edTy" (EVar "a2")) (fa "edLoc" (EVar "a3")) (fa "edBinds" (EVar "a4")))))))
(DTypeSig false "readExternBind" (TyFun (TyCon "SexpCursor") (TyCon "ExternBind")))
(DFunDef false "readExternBind" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "a0") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ERecordCreate "ExternBind" ((fa "ebHost" (EVar "a0")) (fa "ebSymbol" (EVar "a1")) (fa "ebLoc" (EVar "a2")))))))
(DTypeSig false "readDecl" (TyFun (TyCon "SexpCursor") (TyCon "Decl")))
(DFunDef false "readDecl" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "readDeclTagged") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "v"))) (EApp (EApp (EVar "readDeclBare") (EApp (EVar "cursorInt") (EVar "cur"))) (EVar "cur"))))
(DTypeSig false "readDeclBare" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Decl"))))
(DFunDef false "readDeclBare" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltDecl")))
(DTypeSig false "readDeclTagged" (TyFun (TyCon "Int") (TyFun (TyCon "SexpCursor") (TyCon "Decl"))))
(DFunDef false "readDeclTagged" ((PLit (LInt 0)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readLoc") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "DTypeSig") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DFunDef false "readDeclTagged" ((PLit (LInt 1)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readExternDecl") (EVar "cur"))) (DoExpr (EApp (EVar "DExtern") (EVar "a0")))))
(DFunDef false "readDeclTagged" ((PLit (LInt 2)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "cursorList") (EVar "readPat")) (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readExpr") (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false (PVar "a5") (EApp (EVar "readBinderId") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")) (EVar "a4")) (EVar "a5")))))
(DFunDef false "readDeclTagged" ((PLit (LInt 3)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readDataVis") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "cursorList") (EApp (EVar "readOpt") (EVar "readKindAnn"))) (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EApp (EVar "cursorList") (EVar "readVariant")) (EVar "cur"))) (DoLet false false (PVar "a5") (EApp (EApp (EVar "cursorList") (EApp (EVar "cursorList") (EApp (EApp (EVar "readPair") (EVar "readString")) (EVar "readKindAnn")))) (EVar "cur"))) (DoLet false false (PVar "a6") (EApp (EApp (EVar "cursorList") (EVar "readDeriveRef")) (EVar "cur"))) (DoLet false false (PVar "a7") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false (PVar "a8") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a9") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoExpr (ERecordCreate "DData" ((fa "dataVis" (EVar "a0")) (fa "dataName" (EVar "a1")) (fa "dataParams" (EVar "a2")) (fa "dataParamKinds" (EVar "a3")) (fa "dataCtors" (EVar "a4")) (fa "dataCtorBinders" (EVar "a5")) (fa "dataDerives" (EVar "a6")) (fa "dataOrigin" (EVar "a7")) (fa "dataExtern" (EVar "a8")) (fa "dataNameLoc" (EVar "a9")))))))
(DFunDef false "readDeclTagged" ((PLit (LInt 4)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readUsePath") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readLoc") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "DUse") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readDeclTagged" ((PLit (LInt 5)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "readOpt") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "cursorList") (EApp (EApp (EVar "readPair") (EVar "readString")) (EVar "readString"))) (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false (PVar "a5") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DEffect") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")) (EVar "a4")) (EVar "a5")))))
(DFunDef false "readDeclTagged" ((PLit (LInt 6)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "cursorList") (EVar "readPropParam")) (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "a0")) (EVar "a1")) (EVar "a2")) (EVar "a3")))))
(DFunDef false "readDeclTagged" ((PLit (LInt 7)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readExpr") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "DTest") (EVar "a0")) (EVar "a1")) (EVar "a2")))))
(DFunDef false "readDeclTagged" ((PLit (LInt 8)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EApp (EVar "cursorList") (EApp (EVar "readOpt") (EVar "readKindAnn"))) (EVar "cur"))) (DoLet false false (PVar "a5") (EApp (EApp (EVar "cursorList") (EVar "readSuper")) (EVar "cur"))) (DoLet false false (PVar "a6") (EApp (EApp (EVar "cursorList") (EVar "readIfaceMethod")) (EVar "cur"))) (DoLet false false (PVar "a7") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false (PVar "a8") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoExpr (ERecordCreate "DInterface" ((fa "pub" (EVar "a0")) (fa "def" (EVar "a1")) (fa "name" (EVar "a2")) (fa "typarams" (EVar "a3")) (fa "typaramKinds" (EVar "a4")) (fa "supers" (EVar "a5")) (fa "methods" (EVar "a6")) (fa "ifaceOrigin" (EVar "a7")) (fa "ifaceNameLoc" (EVar "a8")))))))
(DFunDef false "readDeclTagged" ((PLit (LInt 9)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "cursorList") (EVar "readTy")) (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "cursorList") (EVar "readRequire")) (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EApp (EVar "cursorList") (EVar "readImplMethod")) (EVar "cur"))) (DoLet false false (PVar "a5") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false (PVar "a6") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoExpr (ERecordCreate "DImpl" ((fa "pub" (EVar "a0")) (fa "iface" (EVar "a1")) (fa "tys" (EVar "a2")) (fa "reqs" (EVar "a3")) (fa "methods" (EVar "a4")) (fa "implOrigin" (EVar "a5")) (fa "implIfaceLoc" (EVar "a6")))))))
(DFunDef false "readDeclTagged" ((PLit (LInt 10)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "cursorList") (EApp (EVar "readOpt") (EVar "readKindAnn"))) (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false (PVar "a5") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false (PVar "a6") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoExpr (ERecordCreate "DTypeAlias" ((fa "tyAliasPub" (EVar "a0")) (fa "tyAliasName" (EVar "a1")) (fa "tyAliasParams" (EVar "a2")) (fa "tyAliasParamKinds" (EVar "a3")) (fa "tyAliasRhs" (EVar "a4")) (fa "tyAliasOrigin" (EVar "a5")) (fa "tyAliasNameLoc" (EVar "a6")))))))
(DFunDef false "readDeclTagged" ((PLit (LInt 11)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a2") (EApp (EApp (EVar "cursorList") (EVar "readString")) (EVar "cur"))) (DoLet false false (PVar "a3") (EApp (EApp (EVar "cursorList") (EApp (EVar "readOpt") (EVar "readKindAnn"))) (EVar "cur"))) (DoLet false false (PVar "a4") (EApp (EVar "readString") (EVar "cur"))) (DoLet false false (PVar "a5") (EApp (EApp (EVar "cursorList") (EApp (EApp (EVar "readPair") (EVar "readString")) (EVar "readKindAnn"))) (EVar "cur"))) (DoLet false false (PVar "a6") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false (PVar "a7") (EApp (EApp (EVar "cursorList") (EVar "readDeriveRef")) (EVar "cur"))) (DoLet false false (PVar "a8") (EApp (EVar "readTyConOrigin") (EVar "cur"))) (DoLet false false (PVar "a9") (EApp (EApp (EVar "readOpt") (EVar "readLoc")) (EVar "cur"))) (DoExpr (ERecordCreate "DNewtype" ((fa "newtypePub" (EVar "a0")) (fa "newtypeName" (EVar "a1")) (fa "newtypeParams" (EVar "a2")) (fa "newtypeParamKinds" (EVar "a3")) (fa "newtypeCtor" (EVar "a4")) (fa "newtypeCtorBinders" (EVar "a5")) (fa "newtypeFieldTy" (EVar "a6")) (fa "newtypeDerives" (EVar "a7")) (fa "newtypeOrigin" (EVar "a8")) (fa "newtypeNameLoc" (EVar "a9")))))))
(DFunDef false "readDeclTagged" ((PLit (LInt 12)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EApp (EVar "cursorList") (EVar "readLetBind")) (EVar "cur"))) (DoExpr (EApp (EApp (EVar "DLetGroup") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readDeclTagged" ((PLit (LInt 13)) (PVar "cur")) (EBlock (DoLet false false (PVar "a0") (EApp (EApp (EVar "cursorList") (EVar "readAttr")) (EVar "cur"))) (DoLet false false (PVar "a1") (EApp (EVar "readDecl") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "DAttrib") (EVar "a0")) (EVar "a1")))))
(DFunDef false "readDeclTagged" (PWild (PVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "dfltDecl")))
