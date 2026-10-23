# META
source_lines=413
stages=DESUGAR,MARK
# SOURCE
-- S-expression values with one canonical rendering and a fail-closed reader.
-- Offsets are UTF-8 byte offsets into the input. `sePath` is empty when the
-- reader itself fails; codecs fill it when a node has the wrong shape.
-- The renderer and the reader agree on the quoting set: an atom is bare
-- unless it is empty or holds whitespace, parens, `"`, `;` or `\`.

import array.{fromList}
import list.{reverse}

-- The two constructors coincide with `Result` by shape only; this is a value tree.
-- lint-disable-next-line rule-clone-type
public export data SExp = SAtom String | SList (List SExp) deriving (Eq, Debug)

public export data SexpError = SexpError {
  seOffset : Int,
  sePath : String,
  seWhat : String,
} deriving (Eq, Debug)

bytesOf : String -> List Int
bytesOf s = toList (stringToUtf8Bytes s)

textOf : List Int -> String
textOf bytes = stringFromUtf8Bytes (fromList bytes)

isWsByte : Int -> Bool
isWsByte b = b == 32 || b == 10 || b == 9 || b == 13

-- Bytes that end a bare atom or force quoting.
isSpecialByte : Int -> Bool
isSpecialByte b =
  isWsByte b || b == 40 || b == 41 || b == 34 || b == 59 || b == 92

needsQuote : String -> Bool
needsQuote s = s == "" || any isSpecialByte (bytesOf s)

escapeByte : Int -> List Int
escapeByte 92 = [92, 92]
escapeByte 34 = [92, 34]
escapeByte 10 = [92, 110]
escapeByte 9 = [92, 116]
escapeByte 13 = [92, 114]
escapeByte b = [b]

renderAtom : String -> String
renderAtom s
  | needsQuote s = textOf ([34] ++ flatMap escapeByte (bytesOf s) ++ [34])
  | otherwise = s

export
renderSExp : SExp -> String
renderSExp (SAtom s) = renderAtom s
renderSExp (SList items) = "(" ++ stringJoin " " (map renderSExp items) ++ ")"

failAt : Int -> String -> Result SexpError a
failAt off what = Err SexpError { seOffset = off, sePath = "", seWhat = what }

-- ── scanning ────────────────────────────────────────────────────────────────
-- Both the tree reader and the cursor scan a `ByteBlock` by index, so an atom
-- costs one slice and no per-character value.

skipWsAt : ByteBlock -> Int -> Int -> Int
skipWsAt b n p
  | p < n && isWsByte (byteBlockGetUnsafe p b) = skipWsAt b n (p + 1)
  | otherwise = p

sliceText : ByteBlock -> Int -> Int -> String
sliceText b i j =
  let blk = byteBlockMake (j - i)
  let _ = byteBlockBlit b i blk 0 (j - i)
  byteBlockToString blk

bareEnd : ByteBlock -> Int -> Int -> Int
bareEnd b n p
  | p < n && not (isSpecialByte (byteBlockGetUnsafe p b)) = bareEnd b n (p + 1)
  | otherwise = p

-- A bare atom may not run into a quote, `;` or `\`.
isStrayByte : Int -> Bool
isStrayByte b = b == 34 || b == 59 || b == 92

-- From just after an opening quote: the index of the closing quote and whether
-- an escape occurred, or `(-1, _)` when the string never closes, or
-- `(-2 - i, _)` when the escape at index `i` is not one the renderer writes.
scanQuote : ByteBlock -> Int -> Int -> Bool -> (Int, Bool)
scanQuote b n p esc
  | p >= n = (-1, esc)
  | otherwise =
    let c = byteBlockGetUnsafe p b
    if c == 34 then
      (p, esc)
    else if c == 92 then
      if p + 1 >= n then
        (-1, esc)
      else if unescapeByte (byteBlockGetUnsafe (p + 1) b) < 0 then
        (-2 - p, esc)
      else
        scanQuote b n (p + 2) True
    else
      scanQuote b n (p + 1) esc

-- The byte an escape letter stands for, or -1.
unescapeByte : Int -> Int
unescapeByte 92 = 92
unescapeByte 34 = 34
unescapeByte 110 = 10
unescapeByte 116 = 9
unescapeByte 114 = 13
unescapeByte _ = -1

unescapeGo : ByteBlock -> Int -> Int -> ByteBlock -> Int -> Int
unescapeGo b i j out k
  | i >= j = k
  | otherwise =
    let c = byteBlockGetUnsafe i b
    if c == 92 then
      let _ =
        byteBlockSetUnsafe k (unescapeByte (byteBlockGetUnsafe (i + 1) b)) out
      unescapeGo b (i + 2) j out (k + 1)
    else
      let _ = byteBlockSetUnsafe k c out
      unescapeGo b (i + 1) j out (k + 1)

-- The text of the quoted atom whose body is the bytes `i` up to `j`.
quotedText : ByteBlock -> Int -> Int -> Bool -> String
quotedText b i j esc
  | esc =
    let out = byteBlockMake (j - i)
    let k = unescapeGo b i j out 0
    byteBlockToString (byteBlockCopyUnsafe k out)
  | otherwise = sliceText b i j

-- ── the tree reader ─────────────────────────────────────────────────────────

-- Reads the node at or after `p0`; returns it with the index after it.
readNode : ByteBlock -> Int -> Int -> Result SexpError (SExp, Int)
readNode b n p0 =
  let p = skipWsAt b n p0
  if p >= n then
    failAt p "unexpected end of input"
  else
    let c = byteBlockGetUnsafe p b
    if c == 40 then
      readItems b n p (p + 1) []
    else if c == 34 then match scanQuote b n (p + 1) False
      (e, esc) =>
        if e >= 0 then
          Ok (SAtom (quotedText b (p + 1) e esc), e + 1)
        else if e == -1 then
          failAt p "unterminated string"
        else
          failAt (-2 - e) "bad escape"
    else if c == 41 then
      failAt p "unbalanced close paren"
    else if c == 59 || c == 92 then
      failAt p "unexpected character outside a quoted atom"
    else
      let e = bareEnd b n p
      if e < n && isStrayByte (byteBlockGetUnsafe e b) then
        failAt e "unexpected character inside a bare atom"
      else
        Ok (SAtom (sliceText b p e), e)

readItems : ByteBlock ->
  Int ->
  Int ->
  Int ->
  List SExp ->
  Result SexpError (SExp, Int)
readItems b n open p0 acc =
  let p = skipWsAt b n p0
  if p >= n then
    failAt open "unbalanced open paren"
  else if byteBlockGetUnsafe p b == 41 then
    Ok (SList (reverse acc), p + 1)
  else match readNode b n p
    Err e => Err e
    Ok (item, q) => readItems b n open q (item :: acc)

export
parseSExp : String -> Result SexpError SExp
parseSExp text =
  let b = byteBlockFromString text
  let n = byteBlockLength b
  let p = skipWsAt b n 0
  if p >= n then
    failAt p "empty input"
  else match readNode b n p
    Err e => Err e
    Ok (node, q) =>
      let r = skipWsAt b n q
      if r >= n then Ok node else failAt r "trailing text after the first node"

-- ── the cursor ──────────────────────────────────────────────────────────────
-- A decoder reads values straight off the bytes, with no `SExp` in between.
-- The first refusal records its offset and moves the cursor to the end of the
-- input, so every later primitive finds nothing and returns a neutral value; a
-- decoder checks `cursorFailed` once at the end and never acts on a
-- half-read value.

export data SexpCursor = SexpCursor {
  scBytes : ByteBlock,
  scLen : Int,
  scPos : Ref Int,
  scFailAt : Ref Int,
}

export
cursorOf : String -> SexpCursor
cursorOf text =
  let b = byteBlockFromString text
  SexpCursor {
    scBytes = b,
    scLen = byteBlockLength b,
    scPos = Ref 0,
    scFailAt = Ref (-1),
  }

export
cursorFailed : SexpCursor -> Bool
cursorFailed cur = cur.scFailAt.value >= 0

-- The byte offset the next primitive reads from, or where the first refusal
-- happened.
export
cursorOffset : SexpCursor -> Int
cursorOffset cur =
  if cursorFailed cur then cur.scFailAt.value else cur.scPos.value

-- Marks the cursor failed and returns [v], for a decoder that finds a value
-- the grammar admits but its type does not.
export
cursorFail : SexpCursor -> a -> a
cursorFail cur v =
  if cursorFailed cur then
    v
  else
    let at = cur.scFailAt
    let r = cur.scPos
    at := r.value
    r := cur.scLen
    v

cursorStep : SexpCursor -> Int -> Unit
cursorStep cur to =
  let r = cur.scPos
  r := to

-- Steps over the byte `cursorPeek` landed on.
export
cursorAdvance : SexpCursor -> Unit
cursorAdvance cur = cursorStep cur (cur.scPos.value + 1)

-- The next significant byte, with the cursor moved onto it; -1 at the end of
-- the input and after a refusal.
export
cursorPeek : SexpCursor -> Int
cursorPeek cur =
  let p = skipWsAt cur.scBytes cur.scLen cur.scPos.value
  let _ = cursorStep cur p
  if p < cur.scLen then byteBlockGetUnsafe p cur.scBytes else -1

-- True once nothing but whitespace is left, and the cursor has not failed.
export
cursorAtEnd : SexpCursor -> Bool
cursorAtEnd cur =
  not (cursorFailed cur)
    && skipWsAt cur.scBytes cur.scLen cur.scPos.value >= cur.scLen

export
cursorOpen : SexpCursor -> Unit
cursorOpen cur =
  if cursorPeek cur == 40 then cursorAdvance cur else cursorFail cur ()

export
cursorClose : SexpCursor -> Unit
cursorClose cur =
  if cursorPeek cur == 41 then cursorAdvance cur else cursorFail cur ()

-- [v], with the cursor left at [p].
stopAt : SexpCursor -> Int -> a -> a
stopAt cur p v =
  let _ = cursorStep cur p
  v

-- The negated value of the decimal digits from `p`; the cursor is left after
-- them.  The sum is carried below zero because the least `Int`'s magnitude is
-- not an `Int`; a digit that would pass the least `Int` fails the cursor.
digitsInto : SexpCursor -> Int -> Int -> Int
digitsInto cur p acc
  | p >= cur.scLen = stopAt cur p acc
  | otherwise =
    let d = byteBlockGetUnsafe p cur.scBytes - 48
    if d >= 0 && d <= 9 then
      if acc < (intMinBound + d) / 10 then
        cursorFail cur 0
      else
        digitsInto cur (p + 1) (acc * 10 - d)
    else
      stopAt cur p acc

-- An optionally negative decimal integer atom.
export
cursorInt : SexpCursor -> Int
cursorInt cur =
  let c = cursorPeek cur
  if c < 0 then
    cursorFail cur 0
  else
    let neg = c == 45
    let start = if neg then cur.scPos.value + 1 else cur.scPos.value
    let v = digitsInto cur start 0
    let p = cur.scPos.value
    if cursorFailed cur
      || p == start
      || p < cur.scLen
        && not (isSpecialByte (byteBlockGetUnsafe p cur.scBytes)) then
      cursorFail cur 0
    else if neg then
      v
    else if v == intMinBound then
      cursorFail cur 0
    else
      0 - v

-- A bare or quoted atom, escapes resolved.
export
cursorAtom : SexpCursor -> String
cursorAtom cur =
  let c = cursorPeek cur
  let p = cur.scPos.value
  if c == 34 then match scanQuote cur.scBytes cur.scLen (p + 1) False
    (e, esc) =>
      if e < 0 then
        cursorFail cur ""
      else
        let _ = cursorStep cur (e + 1)
        quotedText cur.scBytes (p + 1) e esc
  else if c < 0 || isSpecialByte c then
    cursorFail cur ""
  else
    let e = bareEnd cur.scBytes cur.scLen p
    if e < cur.scLen && isStrayByte (byteBlockGetUnsafe e cur.scBytes) then
      cursorFail cur ""
    else
      let _ = cursorStep cur e
      sliceText cur.scBytes p e

-- A bare atom of exactly one byte, as that byte: the compact tag a codec can
-- read without building a string.
export
cursorChar : SexpCursor -> Int
cursorChar cur =
  let c = cursorPeek cur
  let p = cur.scPos.value
  if c < 0 || isSpecialByte c then
    cursorFail cur 0
  else if p + 1 < cur.scLen
    && not (isSpecialByte (byteBlockGetUnsafe (p + 1) cur.scBytes)) then
    cursorFail cur 0
  else
    stopAt cur (p + 1) c

-- `( item ... )`, each item read by [f].
export
cursorList : (SexpCursor -> a) -> SexpCursor -> List a
cursorList f cur =
  let _ = cursorOpen cur
  cursorItems f cur []

cursorItems : (SexpCursor -> a) -> SexpCursor -> List a -> List a
cursorItems f cur acc =
  let c = cursorPeek cur
  if c == 41 then
    let _ = cursorAdvance cur
    reverse acc
  else if c < 0 then
    cursorFail cur (reverse acc)
  else
    cursorItems f cur (f cur :: acc)

shapeError : String -> String -> Result SexpError a
shapeError path what =
  Err SexpError { seOffset = 0, sePath = path, seWhat = what }

export
expectAtom : String -> SExp -> Result SexpError String
expectAtom _ (SAtom s) = Ok s
expectAtom path _ = shapeError path "expected an atom"

export
atomInt : String -> SExp -> Result SexpError Int
atomInt path node = match expectAtom path node
  Err e => Err e
  Ok s => match stringToInt s
    Some n => Ok n
    None => shapeError path "expected an integer"

export
atomBool : String -> SExp -> Result SexpError Bool
atomBool path node = match expectAtom path node
  Err e => Err e
  Ok "true" => Ok True
  Ok "false" => Ok False
  Ok _ => shapeError path "expected true or false"

export
expectList : Int -> String -> SExp -> Result SexpError (List SExp)
expectList arity path (SList items)
  | length items == arity = Ok items
  | otherwise =
    shapeError path ("expected a list of " ++ intToString arity ++ " items")
expectList _ path _ = shapeError path "expected a list"
# DESUGAR
(DUse false (UseGroup ("array") ((mem "fromList" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DData Public "SExp" () ((variant "SAtom" (ConPos (TyCon "String"))) (variant "SList" (ConPos (TyApp (TyCon "List") (TyCon "SExp"))))) ())
(DImpl true "Eq" ((TyCon "SExp")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "SAtom" (PVar "__a0")) (PCon "SAtom" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "SList" (PVar "__a0")) (PCon "SList" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "SExp")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "SAtom" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SAtom ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "SList" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SList ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DData Public "SexpError" () ((variant "SexpError" (ConNamed (field "seOffset" (TyCon "Int")) (field "sePath" (TyCon "String")) (field "seWhat" (TyCon "String"))))) ())
(DImpl true "Eq" ((TyCon "SexpError")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "SexpError" ((rf "seOffset" (PVar "__a0")) (rf "sePath" (PVar "__a1")) (rf "seWhat" (PVar "__a2"))) false) (PRec "SexpError" ((rf "seOffset" (PVar "__b0")) (rf "sePath" (PVar "__b1")) (rf "seWhat" (PVar "__b2"))) false)) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))))))))
(DImpl true "Debug" ((TyCon "SexpError")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "SexpError" ((rf "seOffset" (PVar "__a0")) (rf "sePath" (PVar "__a1")) (rf "seWhat" (PVar "__a2"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "SexpError {")) (ELit (LString " seOffset = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", sePath = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", seWhat = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString " }"))))))))
(DTypeSig false "bytesOf" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "bytesOf" ((PVar "s")) (EApp (EVar "toList") (EApp (EVar "stringToUtf8Bytes") (EVar "s"))))
(DTypeSig false "textOf" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "String")))
(DFunDef false "textOf" ((PVar "bytes")) (EApp (EVar "stringFromUtf8Bytes") (EApp (EVar "fromList") (EVar "bytes"))))
(DTypeSig false "isWsByte" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isWsByte" ((PVar "b")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "b") (ELit (LInt 32))) (EBinOp "==" (EVar "b") (ELit (LInt 10)))) (EBinOp "==" (EVar "b") (ELit (LInt 9)))) (EBinOp "==" (EVar "b") (ELit (LInt 13)))))
(DTypeSig false "isSpecialByte" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isSpecialByte" ((PVar "b")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isWsByte") (EVar "b")) (EBinOp "==" (EVar "b") (ELit (LInt 40)))) (EBinOp "==" (EVar "b") (ELit (LInt 41)))) (EBinOp "==" (EVar "b") (ELit (LInt 34)))) (EBinOp "==" (EVar "b") (ELit (LInt 59)))) (EBinOp "==" (EVar "b") (ELit (LInt 92)))))
(DTypeSig false "needsQuote" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "needsQuote" ((PVar "s")) (EBinOp "||" (EBinOp "==" (EVar "s") (ELit (LString ""))) (EApp (EApp (EVar "any") (EVar "isSpecialByte")) (EApp (EVar "bytesOf") (EVar "s")))))
(DTypeSig false "escapeByte" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "escapeByte" ((PLit (LInt 92))) (EListLit (ELit (LInt 92)) (ELit (LInt 92))))
(DFunDef false "escapeByte" ((PLit (LInt 34))) (EListLit (ELit (LInt 92)) (ELit (LInt 34))))
(DFunDef false "escapeByte" ((PLit (LInt 10))) (EListLit (ELit (LInt 92)) (ELit (LInt 110))))
(DFunDef false "escapeByte" ((PLit (LInt 9))) (EListLit (ELit (LInt 92)) (ELit (LInt 116))))
(DFunDef false "escapeByte" ((PLit (LInt 13))) (EListLit (ELit (LInt 92)) (ELit (LInt 114))))
(DFunDef false "escapeByte" ((PVar "b")) (EListLit (EVar "b")))
(DTypeSig false "renderAtom" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "renderAtom" ((PVar "s")) (EIf (EApp (EVar "needsQuote") (EVar "s")) (EApp (EVar "textOf") (EBinOp "++" (EBinOp "++" (EListLit (ELit (LInt 34))) (EApp (EApp (EVar "flatMap") (EVar "escapeByte")) (EApp (EVar "bytesOf") (EVar "s")))) (EListLit (ELit (LInt 34))))) (EIf (EVar "otherwise") (EVar "s") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "renderSExp" (TyFun (TyCon "SExp") (TyCon "String")))
(DFunDef false "renderSExp" ((PCon "SAtom" (PVar "s"))) (EApp (EVar "renderAtom") (EVar "s")))
(DFunDef false "renderSExp" ((PCon "SList" (PVar "items"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "stringJoin") (ELit (LString " "))) (EApp (EApp (EVar "map") (EVar "renderSExp")) (EVar "items")))) (ELit (LString ")"))))
(DTypeSig false "failAt" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))))
(DFunDef false "failAt" ((PVar "off") (PVar "what")) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (EVar "off")) (fa "sePath" (ELit (LString ""))) (fa "seWhat" (EVar "what"))))))
(DTypeSig false "skipWsAt" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipWsAt" ((PVar "b") (PVar "n") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "n")) (EApp (EVar "isWsByte") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "p")) (EVar "b")))) (EApp (EApp (EApp (EVar "skipWsAt") (EVar "b")) (EVar "n")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "sliceText" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "sliceText" ((PVar "b") (PVar "i") (PVar "j")) (EBlock (DoLet false false (PVar "blk") (EApp (EVar "byteBlockMake") (EBinOp "-" (EVar "j") (EVar "i")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "b")) (EVar "i")) (EVar "blk")) (ELit (LInt 0))) (EBinOp "-" (EVar "j") (EVar "i")))) (DoExpr (EApp (EVar "byteBlockToString") (EVar "blk")))))
(DTypeSig false "bareEnd" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "bareEnd" ((PVar "b") (PVar "n") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "n")) (EApp (EVar "not") (EApp (EVar "isSpecialByte") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "p")) (EVar "b"))))) (EApp (EApp (EApp (EVar "bareEnd") (EVar "b")) (EVar "n")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isStrayByte" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isStrayByte" ((PVar "b")) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "b") (ELit (LInt 34))) (EBinOp "==" (EVar "b") (ELit (LInt 59)))) (EBinOp "==" (EVar "b") (ELit (LInt 92)))))
(DTypeSig false "scanQuote" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyTuple (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "scanQuote" ((PVar "b") (PVar "n") (PVar "p") (PVar "esc")) (EIf (EBinOp ">=" (EVar "p") (EVar "n")) (ETuple (EUnOp "-" (ELit (LInt 1))) (EVar "esc")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "p")) (EVar "b"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LInt 34))) (ETuple (EVar "p") (EVar "esc")) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 92))) (EIf (EBinOp ">=" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "n")) (ETuple (EUnOp "-" (ELit (LInt 1))) (EVar "esc")) (EIf (EBinOp "<" (EApp (EVar "unescapeByte") (EApp (EApp (EVar "byteBlockGetUnsafe") (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "b"))) (ELit (LInt 0))) (ETuple (EBinOp "-" (EUnOp "-" (ELit (LInt 2))) (EVar "p")) (EVar "esc")) (EApp (EApp (EApp (EApp (EVar "scanQuote") (EVar "b")) (EVar "n")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "True")))) (EApp (EApp (EApp (EApp (EVar "scanQuote") (EVar "b")) (EVar "n")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "esc")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "unescapeByte" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "unescapeByte" ((PLit (LInt 92))) (ELit (LInt 92)))
(DFunDef false "unescapeByte" ((PLit (LInt 34))) (ELit (LInt 34)))
(DFunDef false "unescapeByte" ((PLit (LInt 110))) (ELit (LInt 10)))
(DFunDef false "unescapeByte" ((PLit (LInt 116))) (ELit (LInt 9)))
(DFunDef false "unescapeByte" ((PLit (LInt 114))) (ELit (LInt 13)))
(DFunDef false "unescapeByte" (PWild) (EUnOp "-" (ELit (LInt 1))))
(DTypeSig false "unescapeGo" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "unescapeGo" ((PVar "b") (PVar "i") (PVar "j") (PVar "out") (PVar "k")) (EIf (EBinOp ">=" (EVar "i") (EVar "j")) (EVar "k") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "b"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LInt 92))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "byteBlockSetUnsafe") (EVar "k")) (EApp (EVar "unescapeByte") (EApp (EApp (EVar "byteBlockGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "b")))) (EVar "out"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unescapeGo") (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "j")) (EVar "out")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "byteBlockSetUnsafe") (EVar "k")) (EVar "c")) (EVar "out"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unescapeGo") (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "j")) (EVar "out")) (EBinOp "+" (EVar "k") (ELit (LInt 1))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "quotedText" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "String"))))))
(DFunDef false "quotedText" ((PVar "b") (PVar "i") (PVar "j") (PVar "esc")) (EIf (EVar "esc") (EBlock (DoLet false false (PVar "out") (EApp (EVar "byteBlockMake") (EBinOp "-" (EVar "j") (EVar "i")))) (DoLet false false (PVar "k") (EApp (EApp (EApp (EApp (EApp (EVar "unescapeGo") (EVar "b")) (EVar "i")) (EVar "j")) (EVar "out")) (ELit (LInt 0)))) (DoExpr (EApp (EVar "byteBlockToString") (EApp (EApp (EVar "byteBlockCopyUnsafe") (EVar "k")) (EVar "out"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "sliceText") (EVar "b")) (EVar "i")) (EVar "j")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "readNode" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "SExp") (TyCon "Int")))))))
(DFunDef false "readNode" ((PVar "b") (PVar "n") (PVar "p0")) (EBlock (DoLet false false (PVar "p") (EApp (EApp (EApp (EVar "skipWsAt") (EVar "b")) (EVar "n")) (EVar "p0"))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (EVar "n")) (EApp (EApp (EVar "failAt") (EVar "p")) (ELit (LString "unexpected end of input"))) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "p")) (EVar "b"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LInt 40))) (EApp (EApp (EApp (EApp (EApp (EVar "readItems") (EVar "b")) (EVar "n")) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EListLit)) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 34))) (EMatch (EApp (EApp (EApp (EApp (EVar "scanQuote") (EVar "b")) (EVar "n")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "False")) (arm (PTuple (PVar "e") (PVar "esc")) () (EIf (EBinOp ">=" (EVar "e") (ELit (LInt 0))) (EApp (EVar "Ok") (ETuple (EApp (EVar "SAtom") (EApp (EApp (EApp (EApp (EVar "quotedText") (EVar "b")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "e")) (EVar "esc"))) (EBinOp "+" (EVar "e") (ELit (LInt 1))))) (EIf (EBinOp "==" (EVar "e") (EUnOp "-" (ELit (LInt 1)))) (EApp (EApp (EVar "failAt") (EVar "p")) (ELit (LString "unterminated string"))) (EApp (EApp (EVar "failAt") (EBinOp "-" (EUnOp "-" (ELit (LInt 2))) (EVar "e"))) (ELit (LString "bad escape"))))))) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 41))) (EApp (EApp (EVar "failAt") (EVar "p")) (ELit (LString "unbalanced close paren"))) (EIf (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LInt 59))) (EBinOp "==" (EVar "c") (ELit (LInt 92)))) (EApp (EApp (EVar "failAt") (EVar "p")) (ELit (LString "unexpected character outside a quoted atom"))) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "bareEnd") (EVar "b")) (EVar "n")) (EVar "p"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "e") (EVar "n")) (EApp (EVar "isStrayByte") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "e")) (EVar "b")))) (EApp (EApp (EVar "failAt") (EVar "e")) (ELit (LString "unexpected character inside a bare atom"))) (EApp (EVar "Ok") (ETuple (EApp (EVar "SAtom") (EApp (EApp (EApp (EVar "sliceText") (EVar "b")) (EVar "p")) (EVar "e"))) (EVar "e"))))))))))))))))
(DTypeSig false "readItems" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "SExp")) (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "SExp") (TyCon "Int")))))))))
(DFunDef false "readItems" ((PVar "b") (PVar "n") (PVar "open") (PVar "p0") (PVar "acc")) (EBlock (DoLet false false (PVar "p") (EApp (EApp (EApp (EVar "skipWsAt") (EVar "b")) (EVar "n")) (EVar "p0"))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (EVar "n")) (EApp (EApp (EVar "failAt") (EVar "open")) (ELit (LString "unbalanced open paren"))) (EIf (EBinOp "==" (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "p")) (EVar "b")) (ELit (LInt 41))) (EApp (EVar "Ok") (ETuple (EApp (EVar "SList") (EApp (EVar "reverse") (EVar "acc"))) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EMatch (EApp (EApp (EApp (EVar "readNode") (EVar "b")) (EVar "n")) (EVar "p")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "item") (PVar "q"))) () (EApp (EApp (EApp (EApp (EApp (EVar "readItems") (EVar "b")) (EVar "n")) (EVar "open")) (EVar "q")) (EBinOp "::" (EVar "item") (EVar "acc"))))))))))
(DTypeSig true "parseSExp" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "SExp"))))
(DFunDef false "parseSExp" ((PVar "text")) (EBlock (DoLet false false (PVar "b") (EApp (EVar "byteBlockFromString") (EVar "text"))) (DoLet false false (PVar "n") (EApp (EVar "byteBlockLength") (EVar "b"))) (DoLet false false (PVar "p") (EApp (EApp (EApp (EVar "skipWsAt") (EVar "b")) (EVar "n")) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (EVar "n")) (EApp (EApp (EVar "failAt") (EVar "p")) (ELit (LString "empty input"))) (EMatch (EApp (EApp (EApp (EVar "readNode") (EVar "b")) (EVar "n")) (EVar "p")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "node") (PVar "q"))) () (EBlock (DoLet false false (PVar "r") (EApp (EApp (EApp (EVar "skipWsAt") (EVar "b")) (EVar "n")) (EVar "q"))) (DoExpr (EIf (EBinOp ">=" (EVar "r") (EVar "n")) (EApp (EVar "Ok") (EVar "node")) (EApp (EApp (EVar "failAt") (EVar "r")) (ELit (LString "trailing text after the first node"))))))))))))
(DData Abstract "SexpCursor" () ((variant "SexpCursor" (ConNamed (field "scBytes" (TyCon "ByteBlock")) (field "scLen" (TyCon "Int")) (field "scPos" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "scFailAt" (TyApp (TyCon "Ref") (TyCon "Int")))))) ())
(DTypeSig true "cursorOf" (TyFun (TyCon "String") (TyCon "SexpCursor")))
(DFunDef false "cursorOf" ((PVar "text")) (EBlock (DoLet false false (PVar "b") (EApp (EVar "byteBlockFromString") (EVar "text"))) (DoExpr (ERecordCreate "SexpCursor" ((fa "scBytes" (EVar "b")) (fa "scLen" (EApp (EVar "byteBlockLength") (EVar "b"))) (fa "scPos" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "scFailAt" (EApp (EVar "Ref") (EUnOp "-" (ELit (LInt 1))))))))))
(DTypeSig true "cursorFailed" (TyFun (TyCon "SexpCursor") (TyCon "Bool")))
(DFunDef false "cursorFailed" ((PVar "cur")) (EBinOp ">=" (EFieldAccess (EFieldAccess (EVar "cur") "scFailAt") "value") (ELit (LInt 0))))
(DTypeSig true "cursorOffset" (TyFun (TyCon "SexpCursor") (TyCon "Int")))
(DFunDef false "cursorOffset" ((PVar "cur")) (EIf (EApp (EVar "cursorFailed") (EVar "cur")) (EFieldAccess (EFieldAccess (EVar "cur") "scFailAt") "value") (EFieldAccess (EFieldAccess (EVar "cur") "scPos") "value")))
(DTypeSig true "cursorFail" (TyFun (TyCon "SexpCursor") (TyFun (TyVar "a") (TyVar "a"))))
(DFunDef false "cursorFail" ((PVar "cur") (PVar "v")) (EIf (EApp (EVar "cursorFailed") (EVar "cur")) (EVar "v") (EBlock (DoLet false false (PVar "at") (EFieldAccess (EVar "cur") "scFailAt")) (DoLet false false (PVar "r") (EFieldAccess (EVar "cur") "scPos")) (DoExpr (EApp (EApp (EVar "setRef") (EVar "at")) (EFieldAccess (EVar "r") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "r")) (EFieldAccess (EVar "cur") "scLen"))) (DoExpr (EVar "v")))))
(DTypeSig false "cursorStep" (TyFun (TyCon "SexpCursor") (TyFun (TyCon "Int") (TyCon "Unit"))))
(DFunDef false "cursorStep" ((PVar "cur") (PVar "to")) (EBlock (DoLet false false (PVar "r") (EFieldAccess (EVar "cur") "scPos")) (DoExpr (EApp (EApp (EVar "setRef") (EVar "r")) (EVar "to")))))
(DTypeSig true "cursorAdvance" (TyFun (TyCon "SexpCursor") (TyCon "Unit")))
(DFunDef false "cursorAdvance" ((PVar "cur")) (EApp (EApp (EVar "cursorStep") (EVar "cur")) (EBinOp "+" (EFieldAccess (EFieldAccess (EVar "cur") "scPos") "value") (ELit (LInt 1)))))
(DTypeSig true "cursorPeek" (TyFun (TyCon "SexpCursor") (TyCon "Int")))
(DFunDef false "cursorPeek" ((PVar "cur")) (EBlock (DoLet false false (PVar "p") (EApp (EApp (EApp (EVar "skipWsAt") (EFieldAccess (EVar "cur") "scBytes")) (EFieldAccess (EVar "cur") "scLen")) (EFieldAccess (EFieldAccess (EVar "cur") "scPos") "value"))) (DoLet false false PWild (EApp (EApp (EVar "cursorStep") (EVar "cur")) (EVar "p"))) (DoExpr (EIf (EBinOp "<" (EVar "p") (EFieldAccess (EVar "cur") "scLen")) (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "p")) (EFieldAccess (EVar "cur") "scBytes")) (EUnOp "-" (ELit (LInt 1)))))))
(DTypeSig true "cursorAtEnd" (TyFun (TyCon "SexpCursor") (TyCon "Bool")))
(DFunDef false "cursorAtEnd" ((PVar "cur")) (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "cursorFailed") (EVar "cur"))) (EBinOp ">=" (EApp (EApp (EApp (EVar "skipWsAt") (EFieldAccess (EVar "cur") "scBytes")) (EFieldAccess (EVar "cur") "scLen")) (EFieldAccess (EFieldAccess (EVar "cur") "scPos") "value")) (EFieldAccess (EVar "cur") "scLen"))))
(DTypeSig true "cursorOpen" (TyFun (TyCon "SexpCursor") (TyCon "Unit")))
(DFunDef false "cursorOpen" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EApp (EVar "cursorAdvance") (EVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit LUnit))))
(DTypeSig true "cursorClose" (TyFun (TyCon "SexpCursor") (TyCon "Unit")))
(DFunDef false "cursorClose" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 41))) (EApp (EVar "cursorAdvance") (EVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit LUnit))))
(DTypeSig false "stopAt" (TyFun (TyCon "SexpCursor") (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyVar "a")))))
(DFunDef false "stopAt" ((PVar "cur") (PVar "p") (PVar "v")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "cursorStep") (EVar "cur")) (EVar "p"))) (DoExpr (EVar "v"))))
(DTypeSig false "digitsInto" (TyFun (TyCon "SexpCursor") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "digitsInto" ((PVar "cur") (PVar "p") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EFieldAccess (EVar "cur") "scLen")) (EApp (EApp (EApp (EVar "stopAt") (EVar "cur")) (EVar "p")) (EVar "acc")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "d") (EBinOp "-" (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "p")) (EFieldAccess (EVar "cur") "scBytes")) (ELit (LInt 48)))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "d") (ELit (LInt 0))) (EBinOp "<=" (EVar "d") (ELit (LInt 9)))) (EIf (EBinOp "<" (EVar "acc") (EBinOp "/" (EBinOp "+" (EVar "intMinBound") (EVar "d")) (ELit (LInt 10)))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit (LInt 0))) (EApp (EApp (EApp (EVar "digitsInto") (EVar "cur")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EBinOp "-" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EVar "d")))) (EApp (EApp (EApp (EVar "stopAt") (EVar "cur")) (EVar "p")) (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "cursorInt" (TyFun (TyCon "SexpCursor") (TyCon "Int")))
(DFunDef false "cursorInt" ((PVar "cur")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "cursorPeek") (EVar "cur"))) (DoExpr (EIf (EBinOp "<" (EVar "c") (ELit (LInt 0))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit (LInt 0))) (EBlock (DoLet false false (PVar "neg") (EBinOp "==" (EVar "c") (ELit (LInt 45)))) (DoLet false false (PVar "start") (EIf (EVar "neg") (EBinOp "+" (EFieldAccess (EFieldAccess (EVar "cur") "scPos") "value") (ELit (LInt 1))) (EFieldAccess (EFieldAccess (EVar "cur") "scPos") "value"))) (DoLet false false (PVar "v") (EApp (EApp (EApp (EVar "digitsInto") (EVar "cur")) (EVar "start")) (ELit (LInt 0)))) (DoLet false false (PVar "p") (EFieldAccess (EFieldAccess (EVar "cur") "scPos") "value")) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EApp (EVar "cursorFailed") (EVar "cur")) (EBinOp "==" (EVar "p") (EVar "start"))) (EBinOp "&&" (EBinOp "<" (EVar "p") (EFieldAccess (EVar "cur") "scLen")) (EApp (EVar "not") (EApp (EVar "isSpecialByte") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "p")) (EFieldAccess (EVar "cur") "scBytes")))))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit (LInt 0))) (EIf (EVar "neg") (EVar "v") (EIf (EBinOp "==" (EVar "v") (EVar "intMinBound")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "v")))))))))))
(DTypeSig true "cursorAtom" (TyFun (TyCon "SexpCursor") (TyCon "String")))
(DFunDef false "cursorAtom" ((PVar "cur")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "cursorPeek") (EVar "cur"))) (DoLet false false (PVar "p") (EFieldAccess (EFieldAccess (EVar "cur") "scPos") "value")) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LInt 34))) (EMatch (EApp (EApp (EApp (EApp (EVar "scanQuote") (EFieldAccess (EVar "cur") "scBytes")) (EFieldAccess (EVar "cur") "scLen")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "False")) (arm (PTuple (PVar "e") (PVar "esc")) () (EIf (EBinOp "<" (EVar "e") (ELit (LInt 0))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit (LString ""))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "cursorStep") (EVar "cur")) (EBinOp "+" (EVar "e") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "quotedText") (EFieldAccess (EVar "cur") "scBytes")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "e")) (EVar "esc"))))))) (EIf (EBinOp "||" (EBinOp "<" (EVar "c") (ELit (LInt 0))) (EApp (EVar "isSpecialByte") (EVar "c"))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit (LString ""))) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "bareEnd") (EFieldAccess (EVar "cur") "scBytes")) (EFieldAccess (EVar "cur") "scLen")) (EVar "p"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "e") (EFieldAccess (EVar "cur") "scLen")) (EApp (EVar "isStrayByte") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "e")) (EFieldAccess (EVar "cur") "scBytes")))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit (LString ""))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "cursorStep") (EVar "cur")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EVar "sliceText") (EFieldAccess (EVar "cur") "scBytes")) (EVar "p")) (EVar "e"))))))))))))
(DTypeSig true "cursorChar" (TyFun (TyCon "SexpCursor") (TyCon "Int")))
(DFunDef false "cursorChar" ((PVar "cur")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "cursorPeek") (EVar "cur"))) (DoLet false false (PVar "p") (EFieldAccess (EFieldAccess (EVar "cur") "scPos") "value")) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EVar "c") (ELit (LInt 0))) (EApp (EVar "isSpecialByte") (EVar "c"))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit (LInt 0))) (EIf (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EFieldAccess (EVar "cur") "scLen")) (EApp (EVar "not") (EApp (EVar "isSpecialByte") (EApp (EApp (EVar "byteBlockGetUnsafe") (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EFieldAccess (EVar "cur") "scBytes"))))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit (LInt 0))) (EApp (EApp (EApp (EVar "stopAt") (EVar "cur")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "c")))))))
(DTypeSig true "cursorList" (TyFun (TyFun (TyCon "SexpCursor") (TyVar "a")) (TyFun (TyCon "SexpCursor") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "cursorList" ((PVar "f") (PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "cursorItems") (EVar "f")) (EVar "cur")) (EListLit)))))
(DTypeSig false "cursorItems" (TyFun (TyFun (TyCon "SexpCursor") (TyVar "a")) (TyFun (TyCon "SexpCursor") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "cursorItems" ((PVar "f") (PVar "cur") (PVar "acc")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "cursorPeek") (EVar "cur"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LInt 41))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoExpr (EApp (EVar "reverse") (EVar "acc")))) (EIf (EBinOp "<" (EVar "c") (ELit (LInt 0))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EApp (EVar "reverse") (EVar "acc"))) (EApp (EApp (EApp (EVar "cursorItems") (EVar "f")) (EVar "cur")) (EBinOp "::" (EApp (EVar "f") (EVar "cur")) (EVar "acc"))))))))
(DTypeSig false "shapeError" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))))
(DFunDef false "shapeError" ((PVar "path") (PVar "what")) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (EVar "path")) (fa "seWhat" (EVar "what"))))))
(DTypeSig true "expectAtom" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "String")))))
(DFunDef false "expectAtom" (PWild (PCon "SAtom" (PVar "s"))) (EApp (EVar "Ok") (EVar "s")))
(DFunDef false "expectAtom" ((PVar "path") PWild) (EApp (EApp (EVar "shapeError") (EVar "path")) (ELit (LString "expected an atom"))))
(DTypeSig true "atomInt" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Int")))))
(DFunDef false "atomInt" ((PVar "path") (PVar "node")) (EMatch (EApp (EApp (EVar "expectAtom") (EVar "path")) (EVar "node")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "s")) () (EMatch (EApp (EVar "stringToInt") (EVar "s")) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (EVar "n"))) (arm (PCon "None") () (EApp (EApp (EVar "shapeError") (EVar "path")) (ELit (LString "expected an integer"))))))))
(DTypeSig true "atomBool" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Bool")))))
(DFunDef false "atomBool" ((PVar "path") (PVar "node")) (EMatch (EApp (EApp (EVar "expectAtom") (EVar "path")) (EVar "node")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PLit (LString "true"))) () (EApp (EVar "Ok") (EVar "True"))) (arm (PCon "Ok" (PLit (LString "false"))) () (EApp (EVar "Ok") (EVar "False"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "shapeError") (EVar "path")) (ELit (LString "expected true or false"))))))
(DTypeSig true "expectList" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyApp (TyCon "List") (TyCon "SExp")))))))
(DFunDef false "expectList" ((PVar "arity") (PVar "path") (PCon "SList" (PVar "items"))) (EIf (EBinOp "==" (EApp (EVar "length") (EVar "items")) (EVar "arity")) (EApp (EVar "Ok") (EVar "items")) (EIf (EVar "otherwise") (EApp (EApp (EVar "shapeError") (EVar "path")) (EBinOp "++" (EBinOp "++" (ELit (LString "expected a list of ")) (EApp (EVar "intToString") (EVar "arity"))) (ELit (LString " items")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "expectList" (PWild (PVar "path") PWild) (EApp (EApp (EVar "shapeError") (EVar "path")) (ELit (LString "expected a list"))))
# MARK
(DUse false (UseGroup ("array") ((mem "fromList" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DData Public "SExp" () ((variant "SAtom" (ConPos (TyCon "String"))) (variant "SList" (ConPos (TyApp (TyCon "List") (TyCon "SExp"))))) ())
(DImpl true "Eq" ((TyCon "SExp")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "SAtom" (PVar "__a0")) (PCon "SAtom" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "SList" (PVar "__a0")) (PCon "SList" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "SExp")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "SAtom" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SAtom ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "SList" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SList ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DData Public "SexpError" () ((variant "SexpError" (ConNamed (field "seOffset" (TyCon "Int")) (field "sePath" (TyCon "String")) (field "seWhat" (TyCon "String"))))) ())
(DImpl true "Eq" ((TyCon "SexpError")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "SexpError" ((rf "seOffset" (PVar "__a0")) (rf "sePath" (PVar "__a1")) (rf "seWhat" (PVar "__a2"))) false) (PRec "SexpError" ((rf "seOffset" (PVar "__b0")) (rf "sePath" (PVar "__b1")) (rf "seWhat" (PVar "__b2"))) false)) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))))))))
(DImpl true "Debug" ((TyCon "SexpError")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "SexpError" ((rf "seOffset" (PVar "__a0")) (rf "sePath" (PVar "__a1")) (rf "seWhat" (PVar "__a2"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "SexpError {")) (ELit (LString " seOffset = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", sePath = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", seWhat = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString " }"))))))))
(DTypeSig false "bytesOf" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "bytesOf" ((PVar "s")) (EApp (EMethodRef "toList") (EApp (EVar "stringToUtf8Bytes") (EVar "s"))))
(DTypeSig false "textOf" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "String")))
(DFunDef false "textOf" ((PVar "bytes")) (EApp (EVar "stringFromUtf8Bytes") (EApp (EVar "fromList") (EVar "bytes"))))
(DTypeSig false "isWsByte" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isWsByte" ((PVar "b")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "b") (ELit (LInt 32))) (EBinOp "==" (EVar "b") (ELit (LInt 10)))) (EBinOp "==" (EVar "b") (ELit (LInt 9)))) (EBinOp "==" (EVar "b") (ELit (LInt 13)))))
(DTypeSig false "isSpecialByte" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isSpecialByte" ((PVar "b")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isWsByte") (EVar "b")) (EBinOp "==" (EVar "b") (ELit (LInt 40)))) (EBinOp "==" (EVar "b") (ELit (LInt 41)))) (EBinOp "==" (EVar "b") (ELit (LInt 34)))) (EBinOp "==" (EVar "b") (ELit (LInt 59)))) (EBinOp "==" (EVar "b") (ELit (LInt 92)))))
(DTypeSig false "needsQuote" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "needsQuote" ((PVar "s")) (EBinOp "||" (EBinOp "==" (EVar "s") (ELit (LString ""))) (EApp (EApp (EDictApp "any") (EVar "isSpecialByte")) (EApp (EVar "bytesOf") (EVar "s")))))
(DTypeSig false "escapeByte" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "escapeByte" ((PLit (LInt 92))) (EListLit (ELit (LInt 92)) (ELit (LInt 92))))
(DFunDef false "escapeByte" ((PLit (LInt 34))) (EListLit (ELit (LInt 92)) (ELit (LInt 34))))
(DFunDef false "escapeByte" ((PLit (LInt 10))) (EListLit (ELit (LInt 92)) (ELit (LInt 110))))
(DFunDef false "escapeByte" ((PLit (LInt 9))) (EListLit (ELit (LInt 92)) (ELit (LInt 116))))
(DFunDef false "escapeByte" ((PLit (LInt 13))) (EListLit (ELit (LInt 92)) (ELit (LInt 114))))
(DFunDef false "escapeByte" ((PVar "b")) (EListLit (EVar "b")))
(DTypeSig false "renderAtom" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "renderAtom" ((PVar "s")) (EIf (EApp (EVar "needsQuote") (EVar "s")) (EApp (EVar "textOf") (EBinOp "++" (EBinOp "++" (EListLit (ELit (LInt 34))) (EApp (EApp (EDictApp "flatMap") (EVar "escapeByte")) (EApp (EVar "bytesOf") (EVar "s")))) (EListLit (ELit (LInt 34))))) (EIf (EVar "otherwise") (EVar "s") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "renderSExp" (TyFun (TyCon "SExp") (TyCon "String")))
(DFunDef false "renderSExp" ((PCon "SAtom" (PVar "s"))) (EApp (EVar "renderAtom") (EVar "s")))
(DFunDef false "renderSExp" ((PCon "SList" (PVar "items"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "stringJoin") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EVar "renderSExp")) (EVar "items")))) (ELit (LString ")"))))
(DTypeSig false "failAt" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))))
(DFunDef false "failAt" ((PVar "off") (PVar "what")) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (EVar "off")) (fa "sePath" (ELit (LString ""))) (fa "seWhat" (EVar "what"))))))
(DTypeSig false "skipWsAt" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipWsAt" ((PVar "b") (PVar "n") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "n")) (EApp (EVar "isWsByte") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "p")) (EVar "b")))) (EApp (EApp (EApp (EVar "skipWsAt") (EVar "b")) (EVar "n")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "sliceText" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "sliceText" ((PVar "b") (PVar "i") (PVar "j")) (EBlock (DoLet false false (PVar "blk") (EApp (EVar "byteBlockMake") (EBinOp "-" (EVar "j") (EVar "i")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "b")) (EVar "i")) (EVar "blk")) (ELit (LInt 0))) (EBinOp "-" (EVar "j") (EVar "i")))) (DoExpr (EApp (EVar "byteBlockToString") (EVar "blk")))))
(DTypeSig false "bareEnd" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "bareEnd" ((PVar "b") (PVar "n") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "n")) (EApp (EVar "not") (EApp (EVar "isSpecialByte") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "p")) (EVar "b"))))) (EApp (EApp (EApp (EVar "bareEnd") (EVar "b")) (EVar "n")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isStrayByte" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isStrayByte" ((PVar "b")) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "b") (ELit (LInt 34))) (EBinOp "==" (EVar "b") (ELit (LInt 59)))) (EBinOp "==" (EVar "b") (ELit (LInt 92)))))
(DTypeSig false "scanQuote" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyTuple (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "scanQuote" ((PVar "b") (PVar "n") (PVar "p") (PVar "esc")) (EIf (EBinOp ">=" (EVar "p") (EVar "n")) (ETuple (EUnOp "-" (ELit (LInt 1))) (EVar "esc")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "p")) (EVar "b"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LInt 34))) (ETuple (EVar "p") (EVar "esc")) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 92))) (EIf (EBinOp ">=" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "n")) (ETuple (EUnOp "-" (ELit (LInt 1))) (EVar "esc")) (EIf (EBinOp "<" (EApp (EVar "unescapeByte") (EApp (EApp (EVar "byteBlockGetUnsafe") (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "b"))) (ELit (LInt 0))) (ETuple (EBinOp "-" (EUnOp "-" (ELit (LInt 2))) (EVar "p")) (EVar "esc")) (EApp (EApp (EApp (EApp (EVar "scanQuote") (EVar "b")) (EVar "n")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "True")))) (EApp (EApp (EApp (EApp (EVar "scanQuote") (EVar "b")) (EVar "n")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "esc")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "unescapeByte" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "unescapeByte" ((PLit (LInt 92))) (ELit (LInt 92)))
(DFunDef false "unescapeByte" ((PLit (LInt 34))) (ELit (LInt 34)))
(DFunDef false "unescapeByte" ((PLit (LInt 110))) (ELit (LInt 10)))
(DFunDef false "unescapeByte" ((PLit (LInt 116))) (ELit (LInt 9)))
(DFunDef false "unescapeByte" ((PLit (LInt 114))) (ELit (LInt 13)))
(DFunDef false "unescapeByte" (PWild) (EUnOp "-" (ELit (LInt 1))))
(DTypeSig false "unescapeGo" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "unescapeGo" ((PVar "b") (PVar "i") (PVar "j") (PVar "out") (PVar "k")) (EIf (EBinOp ">=" (EVar "i") (EVar "j")) (EVar "k") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "b"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LInt 92))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "byteBlockSetUnsafe") (EVar "k")) (EApp (EVar "unescapeByte") (EApp (EApp (EVar "byteBlockGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "b")))) (EVar "out"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unescapeGo") (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "j")) (EVar "out")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "byteBlockSetUnsafe") (EVar "k")) (EVar "c")) (EVar "out"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unescapeGo") (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "j")) (EVar "out")) (EBinOp "+" (EVar "k") (ELit (LInt 1))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "quotedText" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "String"))))))
(DFunDef false "quotedText" ((PVar "b") (PVar "i") (PVar "j") (PVar "esc")) (EIf (EVar "esc") (EBlock (DoLet false false (PVar "out") (EApp (EVar "byteBlockMake") (EBinOp "-" (EVar "j") (EVar "i")))) (DoLet false false (PVar "k") (EApp (EApp (EApp (EApp (EApp (EVar "unescapeGo") (EVar "b")) (EVar "i")) (EVar "j")) (EVar "out")) (ELit (LInt 0)))) (DoExpr (EApp (EVar "byteBlockToString") (EApp (EApp (EVar "byteBlockCopyUnsafe") (EVar "k")) (EVar "out"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "sliceText") (EVar "b")) (EVar "i")) (EVar "j")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "readNode" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "SExp") (TyCon "Int")))))))
(DFunDef false "readNode" ((PVar "b") (PVar "n") (PVar "p0")) (EBlock (DoLet false false (PVar "p") (EApp (EApp (EApp (EVar "skipWsAt") (EVar "b")) (EVar "n")) (EVar "p0"))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (EVar "n")) (EApp (EApp (EVar "failAt") (EVar "p")) (ELit (LString "unexpected end of input"))) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "p")) (EVar "b"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LInt 40))) (EApp (EApp (EApp (EApp (EApp (EVar "readItems") (EVar "b")) (EVar "n")) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EListLit)) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 34))) (EMatch (EApp (EApp (EApp (EApp (EVar "scanQuote") (EVar "b")) (EVar "n")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "False")) (arm (PTuple (PVar "e") (PVar "esc")) () (EIf (EBinOp ">=" (EVar "e") (ELit (LInt 0))) (EApp (EVar "Ok") (ETuple (EApp (EVar "SAtom") (EApp (EApp (EApp (EApp (EVar "quotedText") (EVar "b")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "e")) (EVar "esc"))) (EBinOp "+" (EVar "e") (ELit (LInt 1))))) (EIf (EBinOp "==" (EVar "e") (EUnOp "-" (ELit (LInt 1)))) (EApp (EApp (EVar "failAt") (EVar "p")) (ELit (LString "unterminated string"))) (EApp (EApp (EVar "failAt") (EBinOp "-" (EUnOp "-" (ELit (LInt 2))) (EVar "e"))) (ELit (LString "bad escape"))))))) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 41))) (EApp (EApp (EVar "failAt") (EVar "p")) (ELit (LString "unbalanced close paren"))) (EIf (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LInt 59))) (EBinOp "==" (EVar "c") (ELit (LInt 92)))) (EApp (EApp (EVar "failAt") (EVar "p")) (ELit (LString "unexpected character outside a quoted atom"))) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "bareEnd") (EVar "b")) (EVar "n")) (EVar "p"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "e") (EVar "n")) (EApp (EVar "isStrayByte") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "e")) (EVar "b")))) (EApp (EApp (EVar "failAt") (EVar "e")) (ELit (LString "unexpected character inside a bare atom"))) (EApp (EVar "Ok") (ETuple (EApp (EVar "SAtom") (EApp (EApp (EApp (EVar "sliceText") (EVar "b")) (EVar "p")) (EVar "e"))) (EVar "e"))))))))))))))))
(DTypeSig false "readItems" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "SExp")) (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "SExp") (TyCon "Int")))))))))
(DFunDef false "readItems" ((PVar "b") (PVar "n") (PVar "open") (PVar "p0") (PVar "acc")) (EBlock (DoLet false false (PVar "p") (EApp (EApp (EApp (EVar "skipWsAt") (EVar "b")) (EVar "n")) (EVar "p0"))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (EVar "n")) (EApp (EApp (EVar "failAt") (EVar "open")) (ELit (LString "unbalanced open paren"))) (EIf (EBinOp "==" (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "p")) (EVar "b")) (ELit (LInt 41))) (EApp (EVar "Ok") (ETuple (EApp (EVar "SList") (EApp (EVar "reverse") (EVar "acc"))) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EMatch (EApp (EApp (EApp (EVar "readNode") (EVar "b")) (EVar "n")) (EVar "p")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "item") (PVar "q"))) () (EApp (EApp (EApp (EApp (EApp (EVar "readItems") (EVar "b")) (EVar "n")) (EVar "open")) (EVar "q")) (EBinOp "::" (EVar "item") (EVar "acc"))))))))))
(DTypeSig true "parseSExp" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "SExp"))))
(DFunDef false "parseSExp" ((PVar "text")) (EBlock (DoLet false false (PVar "b") (EApp (EVar "byteBlockFromString") (EVar "text"))) (DoLet false false (PVar "n") (EApp (EVar "byteBlockLength") (EVar "b"))) (DoLet false false (PVar "p") (EApp (EApp (EApp (EVar "skipWsAt") (EVar "b")) (EVar "n")) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (EVar "n")) (EApp (EApp (EVar "failAt") (EVar "p")) (ELit (LString "empty input"))) (EMatch (EApp (EApp (EApp (EVar "readNode") (EVar "b")) (EVar "n")) (EVar "p")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "node") (PVar "q"))) () (EBlock (DoLet false false (PVar "r") (EApp (EApp (EApp (EVar "skipWsAt") (EVar "b")) (EVar "n")) (EVar "q"))) (DoExpr (EIf (EBinOp ">=" (EVar "r") (EVar "n")) (EApp (EVar "Ok") (EVar "node")) (EApp (EApp (EVar "failAt") (EVar "r")) (ELit (LString "trailing text after the first node"))))))))))))
(DData Abstract "SexpCursor" () ((variant "SexpCursor" (ConNamed (field "scBytes" (TyCon "ByteBlock")) (field "scLen" (TyCon "Int")) (field "scPos" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "scFailAt" (TyApp (TyCon "Ref") (TyCon "Int")))))) ())
(DTypeSig true "cursorOf" (TyFun (TyCon "String") (TyCon "SexpCursor")))
(DFunDef false "cursorOf" ((PVar "text")) (EBlock (DoLet false false (PVar "b") (EApp (EVar "byteBlockFromString") (EVar "text"))) (DoExpr (ERecordCreate "SexpCursor" ((fa "scBytes" (EVar "b")) (fa "scLen" (EApp (EVar "byteBlockLength") (EVar "b"))) (fa "scPos" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "scFailAt" (EApp (EVar "Ref") (EUnOp "-" (ELit (LInt 1))))))))))
(DTypeSig true "cursorFailed" (TyFun (TyCon "SexpCursor") (TyCon "Bool")))
(DFunDef false "cursorFailed" ((PVar "cur")) (EBinOp ">=" (EFieldAccess (EFieldAccess (EVar "cur") "scFailAt") "value") (ELit (LInt 0))))
(DTypeSig true "cursorOffset" (TyFun (TyCon "SexpCursor") (TyCon "Int")))
(DFunDef false "cursorOffset" ((PVar "cur")) (EIf (EApp (EVar "cursorFailed") (EVar "cur")) (EFieldAccess (EFieldAccess (EVar "cur") "scFailAt") "value") (EFieldAccess (EFieldAccess (EVar "cur") "scPos") "value")))
(DTypeSig true "cursorFail" (TyFun (TyCon "SexpCursor") (TyFun (TyVar "a") (TyVar "a"))))
(DFunDef false "cursorFail" ((PVar "cur") (PVar "v")) (EIf (EApp (EVar "cursorFailed") (EVar "cur")) (EVar "v") (EBlock (DoLet false false (PVar "at") (EFieldAccess (EVar "cur") "scFailAt")) (DoLet false false (PVar "r") (EFieldAccess (EVar "cur") "scPos")) (DoExpr (EApp (EApp (EVar "setRef") (EVar "at")) (EFieldAccess (EVar "r") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "r")) (EFieldAccess (EVar "cur") "scLen"))) (DoExpr (EVar "v")))))
(DTypeSig false "cursorStep" (TyFun (TyCon "SexpCursor") (TyFun (TyCon "Int") (TyCon "Unit"))))
(DFunDef false "cursorStep" ((PVar "cur") (PVar "to")) (EBlock (DoLet false false (PVar "r") (EFieldAccess (EVar "cur") "scPos")) (DoExpr (EApp (EApp (EVar "setRef") (EVar "r")) (EVar "to")))))
(DTypeSig true "cursorAdvance" (TyFun (TyCon "SexpCursor") (TyCon "Unit")))
(DFunDef false "cursorAdvance" ((PVar "cur")) (EApp (EApp (EVar "cursorStep") (EVar "cur")) (EBinOp "+" (EFieldAccess (EFieldAccess (EVar "cur") "scPos") "value") (ELit (LInt 1)))))
(DTypeSig true "cursorPeek" (TyFun (TyCon "SexpCursor") (TyCon "Int")))
(DFunDef false "cursorPeek" ((PVar "cur")) (EBlock (DoLet false false (PVar "p") (EApp (EApp (EApp (EVar "skipWsAt") (EFieldAccess (EVar "cur") "scBytes")) (EFieldAccess (EVar "cur") "scLen")) (EFieldAccess (EFieldAccess (EVar "cur") "scPos") "value"))) (DoLet false false PWild (EApp (EApp (EVar "cursorStep") (EVar "cur")) (EVar "p"))) (DoExpr (EIf (EBinOp "<" (EVar "p") (EFieldAccess (EVar "cur") "scLen")) (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "p")) (EFieldAccess (EVar "cur") "scBytes")) (EUnOp "-" (ELit (LInt 1)))))))
(DTypeSig true "cursorAtEnd" (TyFun (TyCon "SexpCursor") (TyCon "Bool")))
(DFunDef false "cursorAtEnd" ((PVar "cur")) (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "cursorFailed") (EVar "cur"))) (EBinOp ">=" (EApp (EApp (EApp (EVar "skipWsAt") (EFieldAccess (EVar "cur") "scBytes")) (EFieldAccess (EVar "cur") "scLen")) (EFieldAccess (EFieldAccess (EVar "cur") "scPos") "value")) (EFieldAccess (EVar "cur") "scLen"))))
(DTypeSig true "cursorOpen" (TyFun (TyCon "SexpCursor") (TyCon "Unit")))
(DFunDef false "cursorOpen" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EApp (EVar "cursorAdvance") (EVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit LUnit))))
(DTypeSig true "cursorClose" (TyFun (TyCon "SexpCursor") (TyCon "Unit")))
(DFunDef false "cursorClose" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 41))) (EApp (EVar "cursorAdvance") (EVar "cur")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit LUnit))))
(DTypeSig false "stopAt" (TyFun (TyCon "SexpCursor") (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyVar "a")))))
(DFunDef false "stopAt" ((PVar "cur") (PVar "p") (PVar "v")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "cursorStep") (EVar "cur")) (EVar "p"))) (DoExpr (EVar "v"))))
(DTypeSig false "digitsInto" (TyFun (TyCon "SexpCursor") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "digitsInto" ((PVar "cur") (PVar "p") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EFieldAccess (EVar "cur") "scLen")) (EApp (EApp (EApp (EVar "stopAt") (EVar "cur")) (EVar "p")) (EVar "acc")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "d") (EBinOp "-" (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "p")) (EFieldAccess (EVar "cur") "scBytes")) (ELit (LInt 48)))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "d") (ELit (LInt 0))) (EBinOp "<=" (EVar "d") (ELit (LInt 9)))) (EIf (EBinOp "<" (EVar "acc") (EBinOp "/" (EBinOp "+" (EVar "intMinBound") (EVar "d")) (ELit (LInt 10)))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit (LInt 0))) (EApp (EApp (EApp (EVar "digitsInto") (EVar "cur")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EBinOp "-" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EVar "d")))) (EApp (EApp (EApp (EVar "stopAt") (EVar "cur")) (EVar "p")) (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "cursorInt" (TyFun (TyCon "SexpCursor") (TyCon "Int")))
(DFunDef false "cursorInt" ((PVar "cur")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "cursorPeek") (EVar "cur"))) (DoExpr (EIf (EBinOp "<" (EVar "c") (ELit (LInt 0))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit (LInt 0))) (EBlock (DoLet false false (PVar "neg") (EBinOp "==" (EVar "c") (ELit (LInt 45)))) (DoLet false false (PVar "start") (EIf (EVar "neg") (EBinOp "+" (EFieldAccess (EFieldAccess (EVar "cur") "scPos") "value") (ELit (LInt 1))) (EFieldAccess (EFieldAccess (EVar "cur") "scPos") "value"))) (DoLet false false (PVar "v") (EApp (EApp (EApp (EVar "digitsInto") (EVar "cur")) (EVar "start")) (ELit (LInt 0)))) (DoLet false false (PVar "p") (EFieldAccess (EFieldAccess (EVar "cur") "scPos") "value")) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EApp (EVar "cursorFailed") (EVar "cur")) (EBinOp "==" (EVar "p") (EVar "start"))) (EBinOp "&&" (EBinOp "<" (EVar "p") (EFieldAccess (EVar "cur") "scLen")) (EApp (EVar "not") (EApp (EVar "isSpecialByte") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "p")) (EFieldAccess (EVar "cur") "scBytes")))))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit (LInt 0))) (EIf (EVar "neg") (EVar "v") (EIf (EBinOp "==" (EVar "v") (EVar "intMinBound")) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "v")))))))))))
(DTypeSig true "cursorAtom" (TyFun (TyCon "SexpCursor") (TyCon "String")))
(DFunDef false "cursorAtom" ((PVar "cur")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "cursorPeek") (EVar "cur"))) (DoLet false false (PVar "p") (EFieldAccess (EFieldAccess (EVar "cur") "scPos") "value")) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LInt 34))) (EMatch (EApp (EApp (EApp (EApp (EVar "scanQuote") (EFieldAccess (EVar "cur") "scBytes")) (EFieldAccess (EVar "cur") "scLen")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "False")) (arm (PTuple (PVar "e") (PVar "esc")) () (EIf (EBinOp "<" (EVar "e") (ELit (LInt 0))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit (LString ""))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "cursorStep") (EVar "cur")) (EBinOp "+" (EVar "e") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "quotedText") (EFieldAccess (EVar "cur") "scBytes")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "e")) (EVar "esc"))))))) (EIf (EBinOp "||" (EBinOp "<" (EVar "c") (ELit (LInt 0))) (EApp (EVar "isSpecialByte") (EVar "c"))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit (LString ""))) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "bareEnd") (EFieldAccess (EVar "cur") "scBytes")) (EFieldAccess (EVar "cur") "scLen")) (EVar "p"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "e") (EFieldAccess (EVar "cur") "scLen")) (EApp (EVar "isStrayByte") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "e")) (EFieldAccess (EVar "cur") "scBytes")))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit (LString ""))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "cursorStep") (EVar "cur")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EVar "sliceText") (EFieldAccess (EVar "cur") "scBytes")) (EVar "p")) (EVar "e"))))))))))))
(DTypeSig true "cursorChar" (TyFun (TyCon "SexpCursor") (TyCon "Int")))
(DFunDef false "cursorChar" ((PVar "cur")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "cursorPeek") (EVar "cur"))) (DoLet false false (PVar "p") (EFieldAccess (EFieldAccess (EVar "cur") "scPos") "value")) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EVar "c") (ELit (LInt 0))) (EApp (EVar "isSpecialByte") (EVar "c"))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit (LInt 0))) (EIf (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EFieldAccess (EVar "cur") "scLen")) (EApp (EVar "not") (EApp (EVar "isSpecialByte") (EApp (EApp (EVar "byteBlockGetUnsafe") (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EFieldAccess (EVar "cur") "scBytes"))))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (ELit (LInt 0))) (EApp (EApp (EApp (EVar "stopAt") (EVar "cur")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "c")))))))
(DTypeSig true "cursorList" (TyFun (TyFun (TyCon "SexpCursor") (TyVar "a")) (TyFun (TyCon "SexpCursor") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "cursorList" ((PVar "f") (PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "cursorItems") (EVar "f")) (EVar "cur")) (EListLit)))))
(DTypeSig false "cursorItems" (TyFun (TyFun (TyCon "SexpCursor") (TyVar "a")) (TyFun (TyCon "SexpCursor") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "cursorItems" ((PVar "f") (PVar "cur") (PVar "acc")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "cursorPeek") (EVar "cur"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LInt 41))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoExpr (EApp (EVar "reverse") (EVar "acc")))) (EIf (EBinOp "<" (EVar "c") (ELit (LInt 0))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EApp (EVar "reverse") (EVar "acc"))) (EApp (EApp (EApp (EVar "cursorItems") (EVar "f")) (EVar "cur")) (EBinOp "::" (EApp (EVar "f") (EVar "cur")) (EVar "acc"))))))))
(DTypeSig false "shapeError" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))))
(DFunDef false "shapeError" ((PVar "path") (PVar "what")) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (EVar "path")) (fa "seWhat" (EVar "what"))))))
(DTypeSig true "expectAtom" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "String")))))
(DFunDef false "expectAtom" (PWild (PCon "SAtom" (PVar "s"))) (EApp (EVar "Ok") (EVar "s")))
(DFunDef false "expectAtom" ((PVar "path") PWild) (EApp (EApp (EVar "shapeError") (EVar "path")) (ELit (LString "expected an atom"))))
(DTypeSig true "atomInt" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Int")))))
(DFunDef false "atomInt" ((PVar "path") (PVar "node")) (EMatch (EApp (EApp (EVar "expectAtom") (EVar "path")) (EVar "node")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "s")) () (EMatch (EApp (EVar "stringToInt") (EVar "s")) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (EVar "n"))) (arm (PCon "None") () (EApp (EApp (EVar "shapeError") (EVar "path")) (ELit (LString "expected an integer"))))))))
(DTypeSig true "atomBool" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Bool")))))
(DFunDef false "atomBool" ((PVar "path") (PVar "node")) (EMatch (EApp (EApp (EVar "expectAtom") (EVar "path")) (EVar "node")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PLit (LString "true"))) () (EApp (EVar "Ok") (EVar "True"))) (arm (PCon "Ok" (PLit (LString "false"))) () (EApp (EVar "Ok") (EVar "False"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "shapeError") (EVar "path")) (ELit (LString "expected true or false"))))))
(DTypeSig true "expectList" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyApp (TyCon "List") (TyCon "SExp")))))))
(DFunDef false "expectList" ((PVar "arity") (PVar "path") (PCon "SList" (PVar "items"))) (EIf (EBinOp "==" (EApp (EMethodRef "length") (EVar "items")) (EVar "arity")) (EApp (EVar "Ok") (EVar "items")) (EIf (EVar "otherwise") (EApp (EApp (EVar "shapeError") (EVar "path")) (EBinOp "++" (EBinOp "++" (ELit (LString "expected a list of ")) (EApp (EVar "intToString") (EVar "arity"))) (ELit (LString " items")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "expectList" (PWild (PVar "path") PWild) (EApp (EApp (EVar "shapeError") (EVar "path")) (ELit (LString "expected a list"))))
