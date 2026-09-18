# META
source_lines=147
stages=DESUGAR,MARK
# SOURCE
{- | An immutable string of bytes.

   `Bytes` wraps a sequence of byte values, each `0` to `255`, and hands out
   no way to change it once built. Use it for data that is bytes — a file's
   contents, a hash digest, a UTF-8 encoding — and `Array Int` for a sequence
   of numbers that happen to be small.

   `fromArray` and `toArray` convert; `bytesLength` is the byte count and
   `get` reads one byte. `b[i]` panics on an out-of-range index; `get` is the
   `Option`-returning form. Two byte strings compare lexicographically, as the
   arrays of their bytes do. -}

-- The representation is `Array Int`, one byte per element, and every
-- operation here is that array's operation under a different name.  The type
-- is a `newtype` so that `Bytes` and `Array Int` are distinct at every call
-- site: a function taking bytes cannot be handed codepoints, and the
-- conversion has to be written down.  The wrapper is the whole content of
-- this module today.
--
-- No growable buffer lives here.  `bytebuilder` is the byte accumulator, and
-- a `Bytes`-producing one belongs beside it rather than beside the immutable
-- type.

import core.{Eq, Ord, Ordering, Debug, Option, Index}

{- | The byte-string type.

   The constructor is module-private, so `fromArray` and `toUtf8Bytes` are the
   ways in and `toArray` and `fromUtf8Bytes` are the ways out.

   > bytesLength (fromArray [|1, 2, 3|])
   3 -}
export newtype Bytes = Bytes (Array Int)

-- # Conversion

{- | The byte string holding the elements of `arr`, in order.

   Only the low eight bits of each element carry meaning to the functions
   that read bytes; nothing here masks or rejects an element outside `0` to
   `255`.

   > toArray (fromArray [|104, 105|])
   [|104, 105|] -}
export
fromArray : Array Int -> Bytes
fromArray arr = Bytes arr

{- | The bytes of `b` as an array, in order.

   > toArray (toUtf8Bytes "hi")
   [|104, 105|] -}
export
toArray : Bytes -> Array Int
toArray (Bytes arr) = arr

-- # Reading

{- | The number of bytes in `b`.

   The name is not `length`: that one is `Foldable`'s method, which the
   prelude exports, and `Bytes` cannot implement `Foldable` — the interface
   ranges over a container of some element type, and `Bytes` has no element
   parameter.

   > bytesLength (toUtf8Bytes "héllo")
   6 -}
export
bytesLength : Bytes -> Int
bytesLength (Bytes arr) = arrayLength arr

{- | The byte at index `i`, or `None` when `i` is out of range.

   `b[i]` is the panicking form: on the same out-of-range index, `get`
   answers `None` where `b[i]` raises an index error.

   > get 0 (fromArray [|7, 8, 9|])
   Some 7
   > get 3 (fromArray [|7, 8, 9|])
   None
   > get (-1) (fromArray [|7, 8, 9|])
   None -}
export
get : Int -> Bytes -> Option Int
get i (Bytes arr) =
  if i < 0 || i >= arrayLength arr then None else Some (arrayGetUnsafe i arr)

{- | `b[i]` reads the byte at `i` in `O(1)`.

   Panics with an index error when `i` is out of range; `get` is the
   `Option`-returning form.

   > let b = fromArray [|7, 8, 9|] in b[1]
   8 -}
export impl Index Bytes Int Int where
  index (Bytes arr) i =
    if i < 0 || i >= arrayLength arr then
      indexErrorAt i
    else
      arrayGetUnsafe i arr

-- # Comparison

{- | Two byte strings are equal when they hold the same bytes in the same
   order.

   > eq (fromArray [|1, 2|]) (fromArray [|1, 2|])
   True
   > eq (fromArray [|1, 2|]) (fromArray [|1, 2, 3|])
   False -}
export impl Eq Bytes where
  eq (Bytes a) (Bytes b) = eq a b

{- | Byte strings compare lexicographically, exactly as the arrays of their
   bytes do: byte by byte from the front, and a prefix sorts before what
   extends it.

   > compare (fromArray [|1, 2|]) (fromArray [|1, 3|])
   Lt
   > compare (fromArray [|1, 2|]) (fromArray [|1, 2, 0|])
   Lt -}
export impl Ord Bytes where
  compare (Bytes a) (Bytes b) = compare a b

-- # Text

{- | The UTF-8 encoding of `s`.

   A codepoint outside ASCII contributes several bytes, so the byte count is
   at least the codepoint count and often larger.

   > bytesLength (toUtf8Bytes "héllo")
   6 -}
export
toUtf8Bytes : String -> Bytes
toUtf8Bytes s = Bytes (stringToUtf8Bytes s)

{- | The string encoded by `b`, read as UTF-8.

   Only the low eight bits of each byte are used. On valid UTF-8,
   `fromUtf8Bytes (toUtf8Bytes s)` is `s`.

   > fromUtf8Bytes (toUtf8Bytes "héllo→")
   "héllo→" -}
export
fromUtf8Bytes : Bytes -> String
fromUtf8Bytes (Bytes arr) = stringFromUtf8Bytes arr
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Ordering" false) (mem "Debug" false) (mem "Option" false) (mem "Index" false))))
(DNewtype true "Bytes" () "Bytes" (TyApp (TyCon "Array") (TyCon "Int")) ())
(DTypeSig true "fromArray" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Bytes")))
(DFunDef false "fromArray" ((PVar "arr")) (EApp (EVar "Bytes") (EVar "arr")))
(DTypeSig true "toArray" (TyFun (TyCon "Bytes") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "toArray" ((PCon "Bytes" (PVar "arr"))) (EVar "arr"))
(DTypeSig true "bytesLength" (TyFun (TyCon "Bytes") (TyCon "Int")))
(DFunDef false "bytesLength" ((PCon "Bytes" (PVar "arr"))) (EApp (EVar "arrayLength") (EVar "arr")))
(DTypeSig true "get" (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "get" ((PVar "i") (PCon "Bytes" (PVar "arr"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr")))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))))
(DImpl true "Index" ((TyCon "Bytes") (TyCon "Int") (TyCon "Int")) () ((im "index" ((PCon "Bytes" (PVar "arr")) (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr")))) (EApp (EVar "indexErrorAt") (EVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))))
(DImpl true "Eq" ((TyCon "Bytes")) () ((im "eq" ((PCon "Bytes" (PVar "a")) (PCon "Bytes" (PVar "b"))) (EApp (EApp (EVar "eq") (EVar "a")) (EVar "b")))))
(DImpl true "Ord" ((TyCon "Bytes")) () ((im "compare" ((PCon "Bytes" (PVar "a")) (PCon "Bytes" (PVar "b"))) (EApp (EApp (EVar "compare") (EVar "a")) (EVar "b")))))
(DTypeSig true "toUtf8Bytes" (TyFun (TyCon "String") (TyCon "Bytes")))
(DFunDef false "toUtf8Bytes" ((PVar "s")) (EApp (EVar "Bytes") (EApp (EVar "stringToUtf8Bytes") (EVar "s"))))
(DTypeSig true "fromUtf8Bytes" (TyFun (TyCon "Bytes") (TyCon "String")))
(DFunDef false "fromUtf8Bytes" ((PCon "Bytes" (PVar "arr"))) (EApp (EVar "stringFromUtf8Bytes") (EVar "arr")))
# MARK
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Ordering" false) (mem "Debug" false) (mem "Option" false) (mem "Index" false))))
(DNewtype true "Bytes" () "Bytes" (TyApp (TyCon "Array") (TyCon "Int")) ())
(DTypeSig true "fromArray" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Bytes")))
(DFunDef false "fromArray" ((PVar "arr")) (EApp (EVar "Bytes") (EVar "arr")))
(DTypeSig true "toArray" (TyFun (TyCon "Bytes") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "toArray" ((PCon "Bytes" (PVar "arr"))) (EVar "arr"))
(DTypeSig true "bytesLength" (TyFun (TyCon "Bytes") (TyCon "Int")))
(DFunDef false "bytesLength" ((PCon "Bytes" (PVar "arr"))) (EApp (EVar "arrayLength") (EVar "arr")))
(DTypeSig true "get" (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "get" ((PVar "i") (PCon "Bytes" (PVar "arr"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr")))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))))
(DImpl true "Index" ((TyCon "Bytes") (TyCon "Int") (TyCon "Int")) () ((im "index" ((PCon "Bytes" (PVar "arr")) (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr")))) (EApp (EVar "indexErrorAt") (EVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))))
(DImpl true "Eq" ((TyCon "Bytes")) () ((im "eq" ((PCon "Bytes" (PVar "a")) (PCon "Bytes" (PVar "b"))) (EApp (EApp (EMethodRef "eq") (EVar "a")) (EVar "b")))))
(DImpl true "Ord" ((TyCon "Bytes")) () ((im "compare" ((PCon "Bytes" (PVar "a")) (PCon "Bytes" (PVar "b"))) (EApp (EApp (EMethodRef "compare") (EVar "a")) (EVar "b")))))
(DTypeSig true "toUtf8Bytes" (TyFun (TyCon "String") (TyCon "Bytes")))
(DFunDef false "toUtf8Bytes" ((PVar "s")) (EApp (EVar "Bytes") (EApp (EVar "stringToUtf8Bytes") (EVar "s"))))
(DTypeSig true "fromUtf8Bytes" (TyFun (TyCon "Bytes") (TyCon "String")))
(DFunDef false "fromUtf8Bytes" ((PCon "Bytes" (PVar "arr"))) (EApp (EVar "stringFromUtf8Bytes") (EVar "arr")))
