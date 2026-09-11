# META
source_lines=203
stages=DESUGAR,MARK
# SOURCE
{- | Base32 encoding and decoding of bytes, per RFC 4648.

   Bytes are an `Array Int` with each element from `0` to `255`. `base32Encode`
   uses the lowercase alphabet and never emits `=` padding. `base32Decode`
   accepts exactly that canonical form: uppercase, `=` padding, non-alphabet
   characters, non-zero residual bits, and non-canonical lengths are rejected
   rather than normalized. -}

-- base32Encode/base32Decode declare the same signatures as base64's
-- encode/decode — a signature-only match between two distinct codecs; the
-- rule has no semantic/type-level check to tell them apart, not a real
-- duplicate.
-- lint-disable-file rule-stdlib-reimpl

-- base32/base64/hex property-test helpers share an identical
-- List Int -> Array Int clamp body by design, same precedent as those two
-- files.
-- lint-disable-file rule-duplicate-body

import string.{fromChars, toChars}
import list.{reverse}

alphabet : String
alphabet = "abcdefghijklmnopqrstuvwxyz234567"

alphabetChars : Array Char
alphabetChars = toChars alphabet

alphabetAt : Int -> Char
alphabetAt i = alphabetChars[i]

byteList : Array Int -> Int -> List Int
byteList bytes i =
  if i >= arrayLength bytes then [] else bytes[i] :: byteList bytes (i + 1)

encodeGo : List Int -> Int -> Int -> List Char
encodeGo [] bits buffer =
  if bits == 0 then
    []
  else
    [alphabetAt (bitAnd (shiftLeft buffer (5 - bits)) 31)]
encodeGo (b :: rest) bits buffer =
  let next = bitOr (shiftLeft buffer 8) b
  emitGroups rest (bits + 8) next

emitGroups : List Int -> Int -> Int -> List Char
emitGroups rest bits buffer =
  if bits < 5 then
    encodeGo rest bits buffer
  else
    let remaining = bits - 5
    alphabetAt (bitAnd (shiftRight buffer remaining) 31)
      :: emitGroups rest remaining (bitAnd buffer (shiftLeft 1 remaining - 1))

validBytes : Array Int -> Int -> Bool
validBytes bytes i =
  if i >= arrayLength bytes then
    True
  else
    bytes[i] >= 0 && bytes[i] <= 255 && validBytes bytes (i + 1)

{- | The bytes as lowercase, unpadded base32.

   Panics when an element of `bytes` is outside `0..255`.

   > base32Encode [|102, 111, 111|]
   "mzxw6" -}
export
base32Encode : Array Int -> String
base32Encode bytes =
  if not (validBytes bytes 0) then
    panic "base32: input element outside byte range 0..255"
  else
    fromChars (encodeGo (byteList bytes 0) 0 0)

-- RFC 4648 test vectors, padding stripped (this module's canonical form has
-- none).
-- > base32Encode [||]
-- ""
-- > base32Encode [|102|]
-- "my"
-- > base32Encode [|102, 111|]
-- "mzxq"
-- > base32Encode [|102, 111, 111, 98|]
-- "mzxw6yq"
-- > base32Encode [|102, 111, 111, 98, 97|]
-- "mzxw6ytb"
-- > base32Encode [|102, 111, 111, 98, 97, 114|]
-- "mzxw6ytboi"

digit : Char -> Result String Int
digit c =
  let n = charCode c
  if c == '=' then
    Err "base32: padding is not allowed"
  else if n >= 65 && n <= 90 then
    Err "base32: uppercase is not canonical"
  else if n >= 97 && n <= 122 then
    if n <= 122 then
      let d = n - 97
      if d < 26 then Ok d else Err "base32: invalid alphabet character"
    else
      Err "base32: invalid alphabet character"
  else if n >= 50 && n <= 55 then
    Ok (n - 24)
  else
    Err "base32: invalid alphabet character"

decodeChars : Array Char ->
  Int ->
  Int ->
  Int ->
  List Int ->
  Result String (List Int, Int, Int)
decodeChars chars i bits buffer acc =
  if i >= arrayLength chars then
    Ok (reverse acc, bits, buffer)
  else match digit chars[i]
    Err message => Err message
    Ok d =>
      let next = bitOr (shiftLeft buffer 5) d
      let nextBits = bits + 5
      if nextBits >= 8 then
        let remaining = nextBits - 8
        let b = bitAnd (shiftRight next remaining) 255
        decodeChars
          chars
          (i + 1)
          remaining
          (bitAnd next (shiftLeft 1 remaining - 1))
          (b :: acc)
      else
        decodeChars chars (i + 1) nextBits next acc

{- | The bytes written in canonical (lowercase, unpadded) base32.

   `Err` when the input carries padding, uppercase, a non-alphabet
   character, non-zero trailing bits, or any other non-canonical length.

   > base32Decode "mzxw6"
   Ok [|102, 111, 111|]
   > base32Decode "MZXW6"
   Err "base32: uppercase is not canonical" -}
export
base32Decode : String -> Result String (Array Int)
base32Decode text = match decodeChars (toChars text) 0 0 0 []
  Err message => Err message
  Ok (decoded, bits, residual) =>
    if residual /= 0 then
      Err "base32: non-zero trailing bits"
    else
      let bytes = arrayFromList decoded
      if base32Encode bytes /= text then
        Err "base32: non-canonical length"
      else
        Ok bytes

-- > base32Decode ""
-- Ok [||]
-- > base32Decode "my"
-- Ok [|102|]
-- > base32Decode "mzxq"
-- Ok [|102, 111|]
-- > base32Decode "mzxw6yq"
-- Ok [|102, 111, 111, 98|]
-- > base32Decode "mzxw6ytb"
-- Ok [|102, 111, 111, 98, 97|]
-- > base32Decode "mzxw6ytboi"
-- Ok [|102, 111, 111, 98, 97, 114|]
-- > base32Decode "a1"
-- Err "base32: invalid alphabet character"

-- Every RFC 4648 vector, rejected in its uppercase and (where the RFC pads
-- it) padded forms.
-- > base32Decode "MY"
-- Err "base32: uppercase is not canonical"
-- > base32Decode "MZXQ"
-- Err "base32: uppercase is not canonical"
-- > base32Decode "MZXW6"
-- Err "base32: uppercase is not canonical"
-- > base32Decode "MZXW6YQ"
-- Err "base32: uppercase is not canonical"
-- > base32Decode "MZXW6YTB"
-- Err "base32: uppercase is not canonical"
-- > base32Decode "MZXW6YTBOI"
-- Err "base32: uppercase is not canonical"
-- > base32Decode "my======"
-- Err "base32: padding is not allowed"
-- > base32Decode "mzxq===="
-- Err "base32: padding is not allowed"
-- > base32Decode "mzxw6==="
-- Err "base32: padding is not allowed"
-- > base32Decode "mzxw6yq="
-- Err "base32: padding is not allowed"
-- > base32Decode "mzxw6ytboi======"
-- Err "base32: padding is not allowed"

toByteArray : List Int -> Array Int
toByteArray xs = arrayFromList (map (b => (b % 256 + 256) % 256) xs)

prop "base32 round-trip: decode (encode bs) == Ok bs" (xs : List Int) =
  let bs = toByteArray xs
  base32Decode (base32Encode bs) == Ok bs
# DESUGAR
(DUse false (UseGroup ("string") ((mem "fromChars" false) (mem "toChars" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DTypeSig false "alphabet" (TyCon "String"))
(DFunDef false "alphabet" () (ELit (LString "abcdefghijklmnopqrstuvwxyz234567")))
(DTypeSig false "alphabetChars" (TyApp (TyCon "Array") (TyCon "Char")))
(DFunDef false "alphabetChars" () (EApp (EVar "toChars") (EVar "alphabet")))
(DTypeSig false "alphabetAt" (TyFun (TyCon "Int") (TyCon "Char")))
(DFunDef false "alphabetAt" ((PVar "i")) (EApp (EApp (EVar "index") (EVar "alphabetChars")) (EVar "i")))
(DTypeSig false "byteList" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "byteList" ((PVar "bytes") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (EListLit) (EBinOp "::" (EApp (EApp (EVar "index") (EVar "bytes")) (EVar "i")) (EApp (EApp (EVar "byteList") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))
(DTypeSig false "encodeGo" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "encodeGo" ((PList) (PVar "bits") (PVar "buffer")) (EIf (EBinOp "==" (EVar "bits") (ELit (LInt 0))) (EListLit) (EListLit (EApp (EVar "alphabetAt") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftLeft") (EVar "buffer")) (EBinOp "-" (ELit (LInt 5)) (EVar "bits")))) (ELit (LInt 31)))))))
(DFunDef false "encodeGo" ((PCons (PVar "b") (PVar "rest")) (PVar "bits") (PVar "buffer")) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EVar "buffer")) (ELit (LInt 8)))) (EVar "b"))) (DoExpr (EApp (EApp (EApp (EVar "emitGroups") (EVar "rest")) (EBinOp "+" (EVar "bits") (ELit (LInt 8)))) (EVar "next")))))
(DTypeSig false "emitGroups" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "emitGroups" ((PVar "rest") (PVar "bits") (PVar "buffer")) (EIf (EBinOp "<" (EVar "bits") (ELit (LInt 5))) (EApp (EApp (EApp (EVar "encodeGo") (EVar "rest")) (EVar "bits")) (EVar "buffer")) (EBlock (DoLet false false (PVar "remaining") (EBinOp "-" (EVar "bits") (ELit (LInt 5)))) (DoExpr (EBinOp "::" (EApp (EVar "alphabetAt") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "buffer")) (EVar "remaining"))) (ELit (LInt 31)))) (EApp (EApp (EApp (EVar "emitGroups") (EVar "rest")) (EVar "remaining")) (EApp (EApp (EVar "bitAnd") (EVar "buffer")) (EBinOp "-" (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "remaining")) (ELit (LInt 1))))))))))
(DTypeSig false "validBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "validBytes" ((PVar "bytes") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (EVar "True") (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EApp (EApp (EVar "index") (EVar "bytes")) (EVar "i")) (ELit (LInt 0))) (EBinOp "<=" (EApp (EApp (EVar "index") (EVar "bytes")) (EVar "i")) (ELit (LInt 255)))) (EApp (EApp (EVar "validBytes") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))
(DTypeSig true "base32Encode" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "String")))
(DFunDef false "base32Encode" ((PVar "bytes")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "validBytes") (EVar "bytes")) (ELit (LInt 0)))) (EApp (EVar "panic") (ELit (LString "base32: input element outside byte range 0..255"))) (EApp (EVar "fromChars") (EApp (EApp (EApp (EVar "encodeGo") (EApp (EApp (EVar "byteList") (EVar "bytes")) (ELit (LInt 0)))) (ELit (LInt 0))) (ELit (LInt 0))))))
(DTypeSig false "digit" (TyFun (TyCon "Char") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))
(DFunDef false "digit" ((PVar "c")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "charCode") (EVar "c"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LChar "="))) (EApp (EVar "Err") (ELit (LString "base32: padding is not allowed"))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 65))) (EBinOp "<=" (EVar "n") (ELit (LInt 90)))) (EApp (EVar "Err") (ELit (LString "base32: uppercase is not canonical"))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 97))) (EBinOp "<=" (EVar "n") (ELit (LInt 122)))) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 122))) (EBlock (DoLet false false (PVar "d") (EBinOp "-" (EVar "n") (ELit (LInt 97)))) (DoExpr (EIf (EBinOp "<" (EVar "d") (ELit (LInt 26))) (EApp (EVar "Ok") (EVar "d")) (EApp (EVar "Err") (ELit (LString "base32: invalid alphabet character")))))) (EApp (EVar "Err") (ELit (LString "base32: invalid alphabet character")))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 50))) (EBinOp "<=" (EVar "n") (ELit (LInt 55)))) (EApp (EVar "Ok") (EBinOp "-" (EVar "n") (ELit (LInt 24)))) (EApp (EVar "Err") (ELit (LString "base32: invalid alphabet character"))))))))))
(DTypeSig false "decodeChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int") (TyCon "Int")))))))))
(DFunDef false "decodeChars" ((PVar "chars") (PVar "i") (PVar "bits") (PVar "buffer") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "chars"))) (EApp (EVar "Ok") (ETuple (EApp (EVar "reverse") (EVar "acc")) (EVar "bits") (EVar "buffer"))) (EMatch (EApp (EVar "digit") (EApp (EApp (EVar "index") (EVar "chars")) (EVar "i"))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "Err") (EVar "message"))) (arm (PCon "Ok" (PVar "d")) () (EBlock (DoLet false false (PVar "next") (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EVar "buffer")) (ELit (LInt 5)))) (EVar "d"))) (DoLet false false (PVar "nextBits") (EBinOp "+" (EVar "bits") (ELit (LInt 5)))) (DoExpr (EIf (EBinOp ">=" (EVar "nextBits") (ELit (LInt 8))) (EBlock (DoLet false false (PVar "remaining") (EBinOp "-" (EVar "nextBits") (ELit (LInt 8)))) (DoLet false false (PVar "b") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "next")) (EVar "remaining"))) (ELit (LInt 255)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "decodeChars") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "remaining")) (EApp (EApp (EVar "bitAnd") (EVar "next")) (EBinOp "-" (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "remaining")) (ELit (LInt 1))))) (EBinOp "::" (EVar "b") (EVar "acc"))))) (EApp (EApp (EApp (EApp (EApp (EVar "decodeChars") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "nextBits")) (EVar "next")) (EVar "acc")))))))))
(DTypeSig true "base32Decode" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))
(DFunDef false "base32Decode" ((PVar "text")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "decodeChars") (EApp (EVar "toChars") (EVar "text"))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "Err") (EVar "message"))) (arm (PCon "Ok" (PTuple (PVar "decoded") (PVar "bits") (PVar "residual"))) () (EIf (EBinOp "/=" (EVar "residual") (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "base32: non-zero trailing bits"))) (EBlock (DoLet false false (PVar "bytes") (EApp (EVar "arrayFromList") (EVar "decoded"))) (DoExpr (EIf (EBinOp "/=" (EApp (EVar "base32Encode") (EVar "bytes")) (EVar "text")) (EApp (EVar "Err") (ELit (LString "base32: non-canonical length"))) (EApp (EVar "Ok") (EVar "bytes")))))))))
(DTypeSig false "toByteArray" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "toByteArray" ((PVar "xs")) (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (ELam ((PVar "b")) (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "b") (ELit (LInt 256))) (ELit (LInt 256))) (ELit (LInt 256))))) (EVar "xs"))))
(DProp false "base32 round-trip: decode (encode bs) == Ok bs" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "bs") (EApp (EVar "toByteArray") (EVar "xs"))) (DoExpr (EBinOp "==" (EApp (EVar "base32Decode") (EApp (EVar "base32Encode") (EVar "bs"))) (EApp (EVar "Ok") (EVar "bs"))))))
# MARK
(DUse false (UseGroup ("string") ((mem "fromChars" false) (mem "toChars" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DTypeSig false "alphabet" (TyCon "String"))
(DFunDef false "alphabet" () (ELit (LString "abcdefghijklmnopqrstuvwxyz234567")))
(DTypeSig false "alphabetChars" (TyApp (TyCon "Array") (TyCon "Char")))
(DFunDef false "alphabetChars" () (EApp (EVar "toChars") (EVar "alphabet")))
(DTypeSig false "alphabetAt" (TyFun (TyCon "Int") (TyCon "Char")))
(DFunDef false "alphabetAt" ((PVar "i")) (EApp (EApp (EMethodRef "index") (EVar "alphabetChars")) (EVar "i")))
(DTypeSig false "byteList" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "byteList" ((PVar "bytes") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (EListLit) (EBinOp "::" (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EVar "i")) (EApp (EApp (EVar "byteList") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))
(DTypeSig false "encodeGo" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "encodeGo" ((PList) (PVar "bits") (PVar "buffer")) (EIf (EBinOp "==" (EVar "bits") (ELit (LInt 0))) (EListLit) (EListLit (EApp (EVar "alphabetAt") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftLeft") (EVar "buffer")) (EBinOp "-" (ELit (LInt 5)) (EVar "bits")))) (ELit (LInt 31)))))))
(DFunDef false "encodeGo" ((PCons (PVar "b") (PVar "rest")) (PVar "bits") (PVar "buffer")) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EVar "buffer")) (ELit (LInt 8)))) (EVar "b"))) (DoExpr (EApp (EApp (EApp (EVar "emitGroups") (EVar "rest")) (EBinOp "+" (EVar "bits") (ELit (LInt 8)))) (EVar "next")))))
(DTypeSig false "emitGroups" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "emitGroups" ((PVar "rest") (PVar "bits") (PVar "buffer")) (EIf (EBinOp "<" (EVar "bits") (ELit (LInt 5))) (EApp (EApp (EApp (EVar "encodeGo") (EVar "rest")) (EVar "bits")) (EVar "buffer")) (EBlock (DoLet false false (PVar "remaining") (EBinOp "-" (EVar "bits") (ELit (LInt 5)))) (DoExpr (EBinOp "::" (EApp (EVar "alphabetAt") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "buffer")) (EVar "remaining"))) (ELit (LInt 31)))) (EApp (EApp (EApp (EVar "emitGroups") (EVar "rest")) (EVar "remaining")) (EApp (EApp (EVar "bitAnd") (EVar "buffer")) (EBinOp "-" (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "remaining")) (ELit (LInt 1))))))))))
(DTypeSig false "validBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "validBytes" ((PVar "bytes") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (EVar "True") (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EVar "i")) (ELit (LInt 0))) (EBinOp "<=" (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EVar "i")) (ELit (LInt 255)))) (EApp (EApp (EVar "validBytes") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))
(DTypeSig true "base32Encode" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "String")))
(DFunDef false "base32Encode" ((PVar "bytes")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "validBytes") (EVar "bytes")) (ELit (LInt 0)))) (EApp (EVar "panic") (ELit (LString "base32: input element outside byte range 0..255"))) (EApp (EVar "fromChars") (EApp (EApp (EApp (EVar "encodeGo") (EApp (EApp (EVar "byteList") (EVar "bytes")) (ELit (LInt 0)))) (ELit (LInt 0))) (ELit (LInt 0))))))
(DTypeSig false "digit" (TyFun (TyCon "Char") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))
(DFunDef false "digit" ((PVar "c")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "charCode") (EVar "c"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LChar "="))) (EApp (EVar "Err") (ELit (LString "base32: padding is not allowed"))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 65))) (EBinOp "<=" (EVar "n") (ELit (LInt 90)))) (EApp (EVar "Err") (ELit (LString "base32: uppercase is not canonical"))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 97))) (EBinOp "<=" (EVar "n") (ELit (LInt 122)))) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 122))) (EBlock (DoLet false false (PVar "d") (EBinOp "-" (EVar "n") (ELit (LInt 97)))) (DoExpr (EIf (EBinOp "<" (EVar "d") (ELit (LInt 26))) (EApp (EVar "Ok") (EVar "d")) (EApp (EVar "Err") (ELit (LString "base32: invalid alphabet character")))))) (EApp (EVar "Err") (ELit (LString "base32: invalid alphabet character")))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 50))) (EBinOp "<=" (EVar "n") (ELit (LInt 55)))) (EApp (EVar "Ok") (EBinOp "-" (EVar "n") (ELit (LInt 24)))) (EApp (EVar "Err") (ELit (LString "base32: invalid alphabet character"))))))))))
(DTypeSig false "decodeChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int") (TyCon "Int")))))))))
(DFunDef false "decodeChars" ((PVar "chars") (PVar "i") (PVar "bits") (PVar "buffer") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "chars"))) (EApp (EVar "Ok") (ETuple (EApp (EVar "reverse") (EVar "acc")) (EVar "bits") (EVar "buffer"))) (EMatch (EApp (EVar "digit") (EApp (EApp (EMethodRef "index") (EVar "chars")) (EVar "i"))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "Err") (EVar "message"))) (arm (PCon "Ok" (PVar "d")) () (EBlock (DoLet false false (PVar "next") (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EVar "buffer")) (ELit (LInt 5)))) (EVar "d"))) (DoLet false false (PVar "nextBits") (EBinOp "+" (EVar "bits") (ELit (LInt 5)))) (DoExpr (EIf (EBinOp ">=" (EVar "nextBits") (ELit (LInt 8))) (EBlock (DoLet false false (PVar "remaining") (EBinOp "-" (EVar "nextBits") (ELit (LInt 8)))) (DoLet false false (PVar "b") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "next")) (EVar "remaining"))) (ELit (LInt 255)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "decodeChars") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "remaining")) (EApp (EApp (EVar "bitAnd") (EVar "next")) (EBinOp "-" (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "remaining")) (ELit (LInt 1))))) (EBinOp "::" (EVar "b") (EVar "acc"))))) (EApp (EApp (EApp (EApp (EApp (EVar "decodeChars") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "nextBits")) (EVar "next")) (EVar "acc")))))))))
(DTypeSig true "base32Decode" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))
(DFunDef false "base32Decode" ((PVar "text")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "decodeChars") (EApp (EVar "toChars") (EVar "text"))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "Err") (EVar "message"))) (arm (PCon "Ok" (PTuple (PVar "decoded") (PVar "bits") (PVar "residual"))) () (EIf (EBinOp "/=" (EVar "residual") (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "base32: non-zero trailing bits"))) (EBlock (DoLet false false (PVar "bytes") (EApp (EVar "arrayFromList") (EVar "decoded"))) (DoExpr (EIf (EBinOp "/=" (EApp (EVar "base32Encode") (EVar "bytes")) (EVar "text")) (EApp (EVar "Err") (ELit (LString "base32: non-canonical length"))) (EApp (EVar "Ok") (EVar "bytes")))))))))
(DTypeSig false "toByteArray" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "toByteArray" ((PVar "xs")) (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "b") (ELit (LInt 256))) (ELit (LInt 256))) (ELit (LInt 256))))) (EVar "xs"))))
(DProp false "base32 round-trip: decode (encode bs) == Ok bs" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "bs") (EApp (EVar "toByteArray") (EVar "xs"))) (DoExpr (EBinOp "==" (EApp (EVar "base32Decode") (EApp (EVar "base32Encode") (EVar "bs"))) (EApp (EVar "Ok") (EVar "bs"))))))
