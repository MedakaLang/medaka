# META
source_lines=154
stages=DESUGAR,MARK
# SOURCE
-- Tests for `stdlib/bytes.mdk`'s UTF-8 decoding, and for `string.fromUtf8`,
-- which is the same runtime conversion.
--
-- A `String` is well-formed UTF-8 whichever route built it: the runtime reads
-- bytes that are not UTF-8 with one U+FFFD per maximal ill-formed subpart.
-- The reference reading below is written out here, apart from the runtime, so
-- the grid and the property compare two independent implementations of that
-- rule.

import bytes.{decodeUtf8Lossy, fromArrayAssumeByteDomain}
import list.{replicate}
import string.{fromUtf8, split, toChars}
import test.{expectEqual}

-- # The reference reading

-- The low eight bits of an element, as `fromUtf8` reads it.
refByte : Array Int -> Int -> Int
refByte raw i = (raw[i] % 256 + 256) % 256

refCont : Array Int -> Int -> Bool
refCont raw i =
  let b = refByte raw i
  b >= 0x80 && b <= 0xbf

-- The width (1 to 4) of the well-formed sequence at `i`, or the negated width
-- of its maximal ill-formed subpart: the bytes accepted before it failed, or
-- one when it failed on its lead.
refStep : Array Int -> Int -> Int -> Int
refStep raw i n =
  let b0 = refByte raw i
  if b0 <= 0x7f then
    1
  else if b0 >= 0xc2 && b0 <= 0xdf then
    if i + 1 < n && refCont raw (i + 1) then 2 else -1
  else if b0 >= 0xe0 && b0 <= 0xf4 then
    refStepLong raw i n b0
  else
    -1

refStepLong : Array Int -> Int -> Int -> Int -> Int
refStepLong raw i n b0 =
  let lo = if b0 == 0xe0 then 0xa0 else if b0 == 0xf0 then 0x90 else 0x80
  let hi = if b0 == 0xed then 0x9f else if b0 == 0xf4 then 0x8f else 0xbf
  let width = if b0 >= 0xf0 then 4 else 3
  if i + 1 >= n || refByte raw (i + 1) < lo || refByte raw (i + 1) > hi then
    -1
  else if i + 2 >= n || not (refCont raw (i + 2)) then
    -2
  else if width == 3 then
    3
  else if i + 3 >= n || not (refCont raw (i + 3)) then
    -3
  else
    4

-- The codepoint of the well-formed `width`-byte sequence at `i`.
refCodepoint : Array Int -> Int -> Int -> Int
refCodepoint raw i width =
  let b0 = refByte raw i
  let lead =
    if width == 1 then
      b0
    else if width == 2 then
      b0 % 32
    else if width == 3 then
      b0 % 16
    else
      b0 % 8
  refFold raw (i + 1) (i + width) lead

refFold : Array Int -> Int -> Int -> Int -> Int
refFold raw i end acc =
  if i >= end then
    acc
  else
    refFold raw (i + 1) end (acc * 64 + refByte raw i % 64)

refChar : Int -> Char
refChar cp = match charFromCode cp
  Some c => c
  None => '�'

-- The characters `raw` reads as.
refChars : Array Int -> List Char
refChars raw = refCharsFrom raw 0 (arrayLength raw)

refCharsFrom : Array Int -> Int -> Int -> List Char
refCharsFrom raw i n =
  if i >= n then
    []
  else
    let step = refStep raw i n
    if step > 0 then
      refChar (refCodepoint raw i step) :: refCharsFrom raw (i + step) n
    else
      '�' :: refCharsFrom raw (i - step) n

-- Both runtime conversions of `raw` agree with the reference reading.
lossyAgrees : Array Int -> Bool
lossyAgrees raw =
  let want = arrayFromList (refChars raw)
  toChars (fromUtf8 raw) == want
    && toChars (decodeUtf8Lossy (fromArrayAssumeByteDomain raw)) == want

-- # The grid

-- Second bytes either side of every lead's bound, and ASCII / lead / 0xFF.
lossyEdgeBytes : List Int
lossyEdgeBytes =
  [0x00, 0x41, 0x7f, 0x80, 0x8f, 0x90, 0x9f, 0xa0, 0xbf, 0xc0, 0xff]

-- Every non-ASCII first byte against `lossyEdgeBytes`, then every three- and
-- four-byte lead class against them with a good, bad or missing tail.
lossyGrid : List (Array Int)
lossyGrid =
  flatMap (b0 => flatMap (b1 => [[|b0, b1|]]) lossyEdgeBytes) [0x80..=0xff]
    ++ flatMap
      (b0 =>
        flatMap
          (b1 =>
            flatMap (b2 => lossyTails [b0, b1, b2]) [0x41, 0x80, 0xbf, 0xc0])
          lossyEdgeBytes)
      [0xe0, 0xe1, 0xed, 0xef, 0xf0, 0xf1, 0xf4, 0xf5]

lossyTails : List Int -> List (Array Int)
lossyTails front = [
  arrayFromList front,
  arrayFromList (front ++ [0x41]),
  arrayFromList (front ++ [0x80]),
]

test "fromUtf8 and decodeUtf8Lossy read every lead against edge bytes as the reference does" =
  expectEqual [] (filter (raw => not (lossyAgrees raw)) lossyGrid)

prop "fromUtf8 and decodeUtf8Lossy agree with the reference reading" (raw : Array Int) =
  lossyAgrees raw

-- # Fixed cases

-- 4000 stray continuation bytes are 4000 maximal subparts; `toChars` sizes
-- its result from the count the string caches, so the two must agree.
test "fromUtf8 of stray continuation bytes gives one U+FFFD each" =
  expectEqual (arrayMake 4000 '�') (toChars (fromUtf8 (arrayMake 4000 0x80)))

test "an overlong encoding is U+FFFD, never the ASCII it spells" =
  expectEqual [|'�', '�'|] (toChars (fromUtf8 [|0xc0, 0xae|]))

-- A 0xFF lead is one ill-formed byte, so the comma after it survives:
-- 64 of them alternating with commas split into 65 parts, 64 U+FFFD and the
-- empty part after the last comma.
test "split sees U+FFFD, not a 0xFF lead swallowing the comma after it" =
  let raw = arrayMakeWith 128 (i => if i % 2 == 0 then 255 else 44)
  expectEqual (replicate 64 "�" ++ [""]) (split "," (fromUtf8 raw))
# DESUGAR
(DUse false (UseGroup ("bytes") ((mem "decodeUtf8Lossy" false) (mem "fromArrayAssumeByteDomain" false))))
(DUse false (UseGroup ("list") ((mem "replicate" false))))
(DUse false (UseGroup ("string") ((mem "fromUtf8" false) (mem "split" false) (mem "toChars" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false))))
(DTypeSig false "refByte" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "refByte" ((PVar "raw") (PVar "i")) (EBinOp "%" (EBinOp "+" (EBinOp "%" (EApp (EApp (EVar "index") (EVar "raw")) (EVar "i")) (ELit (LInt 256))) (ELit (LInt 256))) (ELit (LInt 256))))
(DTypeSig false "refCont" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "refCont" ((PVar "raw") (PVar "i")) (EBlock (DoLet false false (PVar "b") (EApp (EApp (EVar "refByte") (EVar "raw")) (EVar "i"))) (DoExpr (EBinOp "&&" (EBinOp ">=" (EVar "b") (ELit (LInt 128))) (EBinOp "<=" (EVar "b") (ELit (LInt 191)))))))
(DTypeSig false "refStep" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "refStep" ((PVar "raw") (PVar "i") (PVar "n")) (EBlock (DoLet false false (PVar "b0") (EApp (EApp (EVar "refByte") (EVar "raw")) (EVar "i"))) (DoExpr (EIf (EBinOp "<=" (EVar "b0") (ELit (LInt 127))) (ELit (LInt 1)) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "b0") (ELit (LInt 194))) (EBinOp "<=" (EVar "b0") (ELit (LInt 223)))) (EIf (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n")) (EApp (EApp (EVar "refCont") (EVar "raw")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (ELit (LInt 2)) (EUnOp "-" (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "b0") (ELit (LInt 224))) (EBinOp "<=" (EVar "b0") (ELit (LInt 244)))) (EApp (EApp (EApp (EApp (EVar "refStepLong") (EVar "raw")) (EVar "i")) (EVar "n")) (EVar "b0")) (EUnOp "-" (ELit (LInt 1)))))))))
(DTypeSig false "refStepLong" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "refStepLong" ((PVar "raw") (PVar "i") (PVar "n") (PVar "b0")) (EBlock (DoLet false false (PVar "lo") (EIf (EBinOp "==" (EVar "b0") (ELit (LInt 224))) (ELit (LInt 160)) (EIf (EBinOp "==" (EVar "b0") (ELit (LInt 240))) (ELit (LInt 144)) (ELit (LInt 128))))) (DoLet false false (PVar "hi") (EIf (EBinOp "==" (EVar "b0") (ELit (LInt 237))) (ELit (LInt 159)) (EIf (EBinOp "==" (EVar "b0") (ELit (LInt 244))) (ELit (LInt 143)) (ELit (LInt 191))))) (DoLet false false (PVar "width") (EIf (EBinOp ">=" (EVar "b0") (ELit (LInt 240))) (ELit (LInt 4)) (ELit (LInt 3)))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n")) (EBinOp "<" (EApp (EApp (EVar "refByte") (EVar "raw")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "lo"))) (EBinOp ">" (EApp (EApp (EVar "refByte") (EVar "raw")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "hi"))) (EUnOp "-" (ELit (LInt 1))) (EIf (EBinOp "||" (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "refCont") (EVar "raw")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EUnOp "-" (ELit (LInt 2))) (EIf (EBinOp "==" (EVar "width") (ELit (LInt 3))) (ELit (LInt 3)) (EIf (EBinOp "||" (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 3))) (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "refCont") (EVar "raw")) (EBinOp "+" (EVar "i") (ELit (LInt 3)))))) (EUnOp "-" (ELit (LInt 3))) (ELit (LInt 4)))))))))
(DTypeSig false "refCodepoint" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "refCodepoint" ((PVar "raw") (PVar "i") (PVar "width")) (EBlock (DoLet false false (PVar "b0") (EApp (EApp (EVar "refByte") (EVar "raw")) (EVar "i"))) (DoLet false false (PVar "lead") (EIf (EBinOp "==" (EVar "width") (ELit (LInt 1))) (EVar "b0") (EIf (EBinOp "==" (EVar "width") (ELit (LInt 2))) (EBinOp "%" (EVar "b0") (ELit (LInt 32))) (EIf (EBinOp "==" (EVar "width") (ELit (LInt 3))) (EBinOp "%" (EVar "b0") (ELit (LInt 16))) (EBinOp "%" (EVar "b0") (ELit (LInt 8))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "refFold") (EVar "raw")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (EVar "width"))) (EVar "lead")))))
(DTypeSig false "refFold" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "refFold" ((PVar "raw") (PVar "i") (PVar "end") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "end")) (EVar "acc") (EApp (EApp (EApp (EApp (EVar "refFold") (EVar "raw")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "end")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 64))) (EBinOp "%" (EApp (EApp (EVar "refByte") (EVar "raw")) (EVar "i")) (ELit (LInt 64)))))))
(DTypeSig false "refChar" (TyFun (TyCon "Int") (TyCon "Char")))
(DFunDef false "refChar" ((PVar "cp")) (EMatch (EApp (EVar "charFromCode") (EVar "cp")) (arm (PCon "Some" (PVar "c")) () (EVar "c")) (arm (PCon "None") () (ELit (LChar "�")))))
(DTypeSig false "refChars" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Char"))))
(DFunDef false "refChars" ((PVar "raw")) (EApp (EApp (EApp (EVar "refCharsFrom") (EVar "raw")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "raw"))))
(DTypeSig false "refCharsFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "refCharsFrom" ((PVar "raw") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EVar "refStep") (EVar "raw")) (EVar "i")) (EVar "n"))) (DoExpr (EIf (EBinOp ">" (EVar "step") (ELit (LInt 0))) (EBinOp "::" (EApp (EVar "refChar") (EApp (EApp (EApp (EVar "refCodepoint") (EVar "raw")) (EVar "i")) (EVar "step"))) (EApp (EApp (EApp (EVar "refCharsFrom") (EVar "raw")) (EBinOp "+" (EVar "i") (EVar "step"))) (EVar "n"))) (EBinOp "::" (ELit (LChar "�")) (EApp (EApp (EApp (EVar "refCharsFrom") (EVar "raw")) (EBinOp "-" (EVar "i") (EVar "step"))) (EVar "n"))))))))
(DTypeSig false "lossyAgrees" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "lossyAgrees" ((PVar "raw")) (EBlock (DoLet false false (PVar "want") (EApp (EVar "arrayFromList") (EApp (EVar "refChars") (EVar "raw")))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EVar "toChars") (EApp (EVar "fromUtf8") (EVar "raw"))) (EVar "want")) (EBinOp "==" (EApp (EVar "toChars") (EApp (EVar "decodeUtf8Lossy") (EApp (EVar "fromArrayAssumeByteDomain") (EVar "raw")))) (EVar "want"))))))
(DTypeSig false "lossyEdgeBytes" (TyApp (TyCon "List") (TyCon "Int")))
(DFunDef false "lossyEdgeBytes" () (EListLit (ELit (LInt 0)) (ELit (LInt 65)) (ELit (LInt 127)) (ELit (LInt 128)) (ELit (LInt 143)) (ELit (LInt 144)) (ELit (LInt 159)) (ELit (LInt 160)) (ELit (LInt 191)) (ELit (LInt 192)) (ELit (LInt 255))))
(DTypeSig false "lossyGrid" (TyApp (TyCon "List") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "lossyGrid" () (EBinOp "++" (EApp (EApp (EVar "flatMap") (ELam ((PVar "b0")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "b1")) (EListLit (EArrayLit (EVar "b0") (EVar "b1"))))) (EVar "lossyEdgeBytes")))) (ERangeList (ELit (LInt 128)) (ELit (LInt 255)) true)) (EApp (EApp (EVar "flatMap") (ELam ((PVar "b0")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "b1")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "b2")) (EApp (EVar "lossyTails") (EListLit (EVar "b0") (EVar "b1") (EVar "b2"))))) (EListLit (ELit (LInt 65)) (ELit (LInt 128)) (ELit (LInt 191)) (ELit (LInt 192)))))) (EVar "lossyEdgeBytes")))) (EListLit (ELit (LInt 224)) (ELit (LInt 225)) (ELit (LInt 237)) (ELit (LInt 239)) (ELit (LInt 240)) (ELit (LInt 241)) (ELit (LInt 244)) (ELit (LInt 245))))))
(DTypeSig false "lossyTails" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "Array") (TyCon "Int")))))
(DFunDef false "lossyTails" ((PVar "front")) (EListLit (EApp (EVar "arrayFromList") (EVar "front")) (EApp (EVar "arrayFromList") (EBinOp "++" (EVar "front") (EListLit (ELit (LInt 65))))) (EApp (EVar "arrayFromList") (EBinOp "++" (EVar "front") (EListLit (ELit (LInt 128)))))))
(DTest false "fromUtf8 and decodeUtf8Lossy read every lead against edge bytes as the reference does" (EApp (EApp (EVar "expectEqual") (EListLit)) (EApp (EApp (EVar "filter") (ELam ((PVar "raw")) (EApp (EVar "not") (EApp (EVar "lossyAgrees") (EVar "raw"))))) (EVar "lossyGrid"))))
(DProp false "fromUtf8 and decodeUtf8Lossy agree with the reference reading" ((pp "raw" (TyApp (TyCon "Array") (TyCon "Int")))) (EApp (EVar "lossyAgrees") (EVar "raw")))
(DTest false "fromUtf8 of stray continuation bytes gives one U+FFFD each" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "arrayMake") (ELit (LInt 4000))) (ELit (LChar "�")))) (EApp (EVar "toChars") (EApp (EVar "fromUtf8") (EApp (EApp (EVar "arrayMake") (ELit (LInt 4000))) (ELit (LInt 128)))))))
(DTest false "an overlong encoding is U+FFFD, never the ASCII it spells" (EApp (EApp (EVar "expectEqual") (EArrayLit (ELit (LChar "�")) (ELit (LChar "�")))) (EApp (EVar "toChars") (EApp (EVar "fromUtf8") (EArrayLit (ELit (LInt 192)) (ELit (LInt 174)))))))
(DTest false "split sees U+FFFD, not a 0xFF lead swallowing the comma after it" (EBlock (DoLet false false (PVar "raw") (EApp (EApp (EVar "arrayMakeWith") (ELit (LInt 128))) (ELam ((PVar "i")) (EIf (EBinOp "==" (EBinOp "%" (EVar "i") (ELit (LInt 2))) (ELit (LInt 0))) (ELit (LInt 255)) (ELit (LInt 44)))))) (DoExpr (EApp (EApp (EVar "expectEqual") (EBinOp "++" (EApp (EApp (EVar "replicate") (ELit (LInt 64))) (ELit (LString "�"))) (EListLit (ELit (LString ""))))) (EApp (EApp (EVar "split") (ELit (LString ","))) (EApp (EVar "fromUtf8") (EVar "raw")))))))
# MARK
(DUse false (UseGroup ("bytes") ((mem "decodeUtf8Lossy" false) (mem "fromArrayAssumeByteDomain" false))))
(DUse false (UseGroup ("list") ((mem "replicate" false))))
(DUse false (UseGroup ("string") ((mem "fromUtf8" false) (mem "split" false) (mem "toChars" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false))))
(DTypeSig false "refByte" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "refByte" ((PVar "raw") (PVar "i")) (EBinOp "%" (EBinOp "+" (EBinOp "%" (EApp (EApp (EMethodRef "index") (EVar "raw")) (EVar "i")) (ELit (LInt 256))) (ELit (LInt 256))) (ELit (LInt 256))))
(DTypeSig false "refCont" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "refCont" ((PVar "raw") (PVar "i")) (EBlock (DoLet false false (PVar "b") (EApp (EApp (EVar "refByte") (EVar "raw")) (EVar "i"))) (DoExpr (EBinOp "&&" (EBinOp ">=" (EVar "b") (ELit (LInt 128))) (EBinOp "<=" (EVar "b") (ELit (LInt 191)))))))
(DTypeSig false "refStep" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "refStep" ((PVar "raw") (PVar "i") (PVar "n")) (EBlock (DoLet false false (PVar "b0") (EApp (EApp (EVar "refByte") (EVar "raw")) (EVar "i"))) (DoExpr (EIf (EBinOp "<=" (EVar "b0") (ELit (LInt 127))) (ELit (LInt 1)) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "b0") (ELit (LInt 194))) (EBinOp "<=" (EVar "b0") (ELit (LInt 223)))) (EIf (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n")) (EApp (EApp (EVar "refCont") (EVar "raw")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (ELit (LInt 2)) (EUnOp "-" (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "b0") (ELit (LInt 224))) (EBinOp "<=" (EVar "b0") (ELit (LInt 244)))) (EApp (EApp (EApp (EApp (EVar "refStepLong") (EVar "raw")) (EVar "i")) (EVar "n")) (EVar "b0")) (EUnOp "-" (ELit (LInt 1)))))))))
(DTypeSig false "refStepLong" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "refStepLong" ((PVar "raw") (PVar "i") (PVar "n") (PVar "b0")) (EBlock (DoLet false false (PVar "lo") (EIf (EBinOp "==" (EVar "b0") (ELit (LInt 224))) (ELit (LInt 160)) (EIf (EBinOp "==" (EVar "b0") (ELit (LInt 240))) (ELit (LInt 144)) (ELit (LInt 128))))) (DoLet false false (PVar "hi") (EIf (EBinOp "==" (EVar "b0") (ELit (LInt 237))) (ELit (LInt 159)) (EIf (EBinOp "==" (EVar "b0") (ELit (LInt 244))) (ELit (LInt 143)) (ELit (LInt 191))))) (DoLet false false (PVar "width") (EIf (EBinOp ">=" (EVar "b0") (ELit (LInt 240))) (ELit (LInt 4)) (ELit (LInt 3)))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n")) (EBinOp "<" (EApp (EApp (EVar "refByte") (EVar "raw")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "lo"))) (EBinOp ">" (EApp (EApp (EVar "refByte") (EVar "raw")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "hi"))) (EUnOp "-" (ELit (LInt 1))) (EIf (EBinOp "||" (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "refCont") (EVar "raw")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EUnOp "-" (ELit (LInt 2))) (EIf (EBinOp "==" (EVar "width") (ELit (LInt 3))) (ELit (LInt 3)) (EIf (EBinOp "||" (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 3))) (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "refCont") (EVar "raw")) (EBinOp "+" (EVar "i") (ELit (LInt 3)))))) (EUnOp "-" (ELit (LInt 3))) (ELit (LInt 4)))))))))
(DTypeSig false "refCodepoint" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "refCodepoint" ((PVar "raw") (PVar "i") (PVar "width")) (EBlock (DoLet false false (PVar "b0") (EApp (EApp (EVar "refByte") (EVar "raw")) (EVar "i"))) (DoLet false false (PVar "lead") (EIf (EBinOp "==" (EVar "width") (ELit (LInt 1))) (EVar "b0") (EIf (EBinOp "==" (EVar "width") (ELit (LInt 2))) (EBinOp "%" (EVar "b0") (ELit (LInt 32))) (EIf (EBinOp "==" (EVar "width") (ELit (LInt 3))) (EBinOp "%" (EVar "b0") (ELit (LInt 16))) (EBinOp "%" (EVar "b0") (ELit (LInt 8))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "refFold") (EVar "raw")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (EVar "width"))) (EVar "lead")))))
(DTypeSig false "refFold" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "refFold" ((PVar "raw") (PVar "i") (PVar "end") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "end")) (EVar "acc") (EApp (EApp (EApp (EApp (EVar "refFold") (EVar "raw")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "end")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 64))) (EBinOp "%" (EApp (EApp (EVar "refByte") (EVar "raw")) (EVar "i")) (ELit (LInt 64)))))))
(DTypeSig false "refChar" (TyFun (TyCon "Int") (TyCon "Char")))
(DFunDef false "refChar" ((PVar "cp")) (EMatch (EApp (EVar "charFromCode") (EVar "cp")) (arm (PCon "Some" (PVar "c")) () (EVar "c")) (arm (PCon "None") () (ELit (LChar "�")))))
(DTypeSig false "refChars" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Char"))))
(DFunDef false "refChars" ((PVar "raw")) (EApp (EApp (EApp (EVar "refCharsFrom") (EVar "raw")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "raw"))))
(DTypeSig false "refCharsFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "refCharsFrom" ((PVar "raw") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EVar "refStep") (EVar "raw")) (EVar "i")) (EVar "n"))) (DoExpr (EIf (EBinOp ">" (EVar "step") (ELit (LInt 0))) (EBinOp "::" (EApp (EVar "refChar") (EApp (EApp (EApp (EVar "refCodepoint") (EVar "raw")) (EVar "i")) (EVar "step"))) (EApp (EApp (EApp (EVar "refCharsFrom") (EVar "raw")) (EBinOp "+" (EVar "i") (EVar "step"))) (EVar "n"))) (EBinOp "::" (ELit (LChar "�")) (EApp (EApp (EApp (EVar "refCharsFrom") (EVar "raw")) (EBinOp "-" (EVar "i") (EVar "step"))) (EVar "n"))))))))
(DTypeSig false "lossyAgrees" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "lossyAgrees" ((PVar "raw")) (EBlock (DoLet false false (PVar "want") (EApp (EVar "arrayFromList") (EApp (EVar "refChars") (EVar "raw")))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EVar "toChars") (EApp (EVar "fromUtf8") (EVar "raw"))) (EVar "want")) (EBinOp "==" (EApp (EVar "toChars") (EApp (EVar "decodeUtf8Lossy") (EApp (EVar "fromArrayAssumeByteDomain") (EVar "raw")))) (EVar "want"))))))
(DTypeSig false "lossyEdgeBytes" (TyApp (TyCon "List") (TyCon "Int")))
(DFunDef false "lossyEdgeBytes" () (EListLit (ELit (LInt 0)) (ELit (LInt 65)) (ELit (LInt 127)) (ELit (LInt 128)) (ELit (LInt 143)) (ELit (LInt 144)) (ELit (LInt 159)) (ELit (LInt 160)) (ELit (LInt 191)) (ELit (LInt 192)) (ELit (LInt 255))))
(DTypeSig false "lossyGrid" (TyApp (TyCon "List") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "lossyGrid" () (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "b0")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "b1")) (EListLit (EArrayLit (EVar "b0") (EVar "b1"))))) (EVar "lossyEdgeBytes")))) (ERangeList (ELit (LInt 128)) (ELit (LInt 255)) true)) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "b0")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "b1")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "b2")) (EApp (EVar "lossyTails") (EListLit (EVar "b0") (EVar "b1") (EVar "b2"))))) (EListLit (ELit (LInt 65)) (ELit (LInt 128)) (ELit (LInt 191)) (ELit (LInt 192)))))) (EVar "lossyEdgeBytes")))) (EListLit (ELit (LInt 224)) (ELit (LInt 225)) (ELit (LInt 237)) (ELit (LInt 239)) (ELit (LInt 240)) (ELit (LInt 241)) (ELit (LInt 244)) (ELit (LInt 245))))))
(DTypeSig false "lossyTails" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "Array") (TyCon "Int")))))
(DFunDef false "lossyTails" ((PVar "front")) (EListLit (EApp (EVar "arrayFromList") (EVar "front")) (EApp (EVar "arrayFromList") (EBinOp "++" (EVar "front") (EListLit (ELit (LInt 65))))) (EApp (EVar "arrayFromList") (EBinOp "++" (EVar "front") (EListLit (ELit (LInt 128)))))))
(DTest false "fromUtf8 and decodeUtf8Lossy read every lead against edge bytes as the reference does" (EApp (EApp (EVar "expectEqual") (EListLit)) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "raw")) (EApp (EVar "not") (EApp (EVar "lossyAgrees") (EVar "raw"))))) (EVar "lossyGrid"))))
(DProp false "fromUtf8 and decodeUtf8Lossy agree with the reference reading" ((pp "raw" (TyApp (TyCon "Array") (TyCon "Int")))) (EApp (EVar "lossyAgrees") (EVar "raw")))
(DTest false "fromUtf8 of stray continuation bytes gives one U+FFFD each" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "arrayMake") (ELit (LInt 4000))) (ELit (LChar "�")))) (EApp (EVar "toChars") (EApp (EVar "fromUtf8") (EApp (EApp (EVar "arrayMake") (ELit (LInt 4000))) (ELit (LInt 128)))))))
(DTest false "an overlong encoding is U+FFFD, never the ASCII it spells" (EApp (EApp (EVar "expectEqual") (EArrayLit (ELit (LChar "�")) (ELit (LChar "�")))) (EApp (EVar "toChars") (EApp (EVar "fromUtf8") (EArrayLit (ELit (LInt 192)) (ELit (LInt 174)))))))
(DTest false "split sees U+FFFD, not a 0xFF lead swallowing the comma after it" (EBlock (DoLet false false (PVar "raw") (EApp (EApp (EVar "arrayMakeWith") (ELit (LInt 128))) (ELam ((PVar "i")) (EIf (EBinOp "==" (EBinOp "%" (EVar "i") (ELit (LInt 2))) (ELit (LInt 0))) (ELit (LInt 255)) (ELit (LInt 44)))))) (DoExpr (EApp (EApp (EVar "expectEqual") (EBinOp "++" (EApp (EApp (EVar "replicate") (ELit (LInt 64))) (ELit (LString "�"))) (EListLit (ELit (LString ""))))) (EApp (EApp (EVar "split") (ELit (LString ","))) (EApp (EVar "fromUtf8") (EVar "raw")))))))
