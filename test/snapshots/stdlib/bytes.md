# META
source_lines=318
stages=DESUGAR,MARK
# SOURCE
{- | An immutable string of bytes.

   `Bytes` wraps a sequence of byte values, each `0` to `255`, and hands out
   no way to change it once built. Use it for data that is bytes, such as a
   file's contents, a hash digest, or a UTF-8 encoding, and `Array Int` for a
   sequence of numbers that happen to be small.

   The bytes are packed one per byte rather than one per machine word, so a
   byte string of `n` bytes occupies `n` bytes.

   The `0` to `255` domain is enforced at the way in. `fromArray` answers
   `None` on an element outside it, so no `Bytes` value holds anything else,
   and `get`, `b[i]`, `eq`, and `compare` all read a byte back.
   `fromArrayAssumeByteDomain` is the unchecked way in, for a caller that has
   already established the range.

   `fromArray` and `toArray` convert; `bytesLength` is the byte count and
   `get` reads one byte. `b[i]` panics on an out-of-range index; `get` is the
   `Option`-returning form. Two byte strings compare lexicographically, as the
   arrays of their bytes do.

   `MutBytes` is the mutable, fixed-length sibling, and the way to build a
   byte string a byte at a time: `mutBytesMake` allocates `n` zero bytes,
   `mutBytesSet` writes one, and `freeze` hands back a `Bytes`. The freeze
   copies, so a write after it never reaches the byte string it produced. -}

-- The representation is a `ByteBlock`, the runtime's packed byte buffer, and
-- every operation here reads it directly rather than through an `Array Int`
-- copy.  The type is a `newtype` rather than the bare block so that `Bytes`
-- and `ByteBlock` are distinct at every call site: a function taking bytes
-- cannot be handed a raw buffer, and the conversion has to be written down.
-- A builtin type head would also claim the identifier `Bytes` in every
-- program at once, and could be neither imported by name nor matched on.
--
-- No growable buffer lives here.  `bytebuilder` is the byte accumulator, and
-- a `Bytes`-producing one belongs beside it rather than beside the immutable
-- type.

import core.{Eq, Ord, Ordering, Debug, Option, Index}
import array.{findIndex}

{- | The byte-string type.

   The constructor is module-private, so `fromArray`,
   `fromArrayAssumeByteDomain` and `toUtf8Bytes` are the ways in and `toArray`
   and `fromUtf8Bytes` are the ways out.

   > map bytesLength (fromArray [|1, 2, 3|])
   Some 3 -}
export newtype Bytes = Bytes ByteBlock

-- # Conversion

{- | The byte string holding the elements of `arr`, or `None` when any element
   falls outside `0` to `255`.

   > map toArray (fromArray [|104, 105|])
   Some [|104, 105|]
   > fromArray [|104, 256|]
   None
   > fromArray [|-1|]
   None -}
export
fromArray : Array Int -> Option Bytes
fromArray arr = match findIndex (b => b < 0 || b > 255) arr
  Some _ => None
  None => Some (Bytes (byteBlockFromIntArray arr))

{- | The byte string holding the elements of `arr`, keeping only the low eight
   bits of each.

   Every element of `arr` must already be in `0` to `255`. Nothing here checks
   that, and an element outside the range is silently masked rather than
   refused, so `-1` and `511` both store as `255`. Prefer `fromArray` unless
   the elements come from a source that already guarantees the range.

   This is transitional. It exists so that callers holding bytes by
   construction move to `Bytes` without paying a scan, and it is removed at
   B6 alongside `toUtf8`/`fromUtf8`.

   > toArray (fromArrayAssumeByteDomain [|104, 105|])
   [|104, 105|]
   > toArray (fromArrayAssumeByteDomain [|300, -1|])
   [|44, 255|] -}
export
fromArrayAssumeByteDomain : Array Int -> Bytes
fromArrayAssumeByteDomain arr = Bytes (byteBlockFromIntArray arr)

{- | The bytes of `b` as an array, in order.

   > toArray (toUtf8Bytes "hi")
   [|104, 105|] -}
export
toArray : Bytes -> Array Int
toArray (Bytes bb) = byteBlockToIntArray bb

-- # Reading

{- | The number of bytes in `b`.

   The name is not `length`: that one is `Foldable`'s method, which the
   prelude exports, and `Bytes` cannot implement `Foldable`. The interface
   ranges over a container of some element type, and `Bytes` has no element
   parameter.

   > bytesLength (toUtf8Bytes "héllo")
   6 -}
export
bytesLength : Bytes -> Int
bytesLength (Bytes bb) = byteBlockLength bb

{- | The byte at index `i`, or `None` when `i` is out of range.

   `b[i]` is the panicking form: on the same out-of-range index, `get`
   answers `None` where `b[i]` raises an index error.

   > get 0 (fromArrayAssumeByteDomain [|7, 8, 9|])
   Some 7
   > get 3 (fromArrayAssumeByteDomain [|7, 8, 9|])
   None
   > get (-1) (fromArrayAssumeByteDomain [|7, 8, 9|])
   None -}
export
get : Int -> Bytes -> Option Int
get i (Bytes bb) =
  if i < 0 || i >= byteBlockLength bb then
    None
  else
    Some (byteBlockGetUnsafe i bb)

{- | `b[i]` reads the byte at `i` in `O(1)`.

   Panics with an index error when `i` is out of range; `get` is the
   `Option`-returning form.

   > let b = fromArrayAssumeByteDomain [|7, 8, 9|] in b[1]
   8 -}
export impl Index Bytes Int Int where
  index (Bytes bb) i =
    if i < 0 || i >= byteBlockLength bb then
      indexErrorAt i
    else
      byteBlockGetUnsafe i bb

-- # Comparison

-- `eq` and `compare` walk the two blocks a byte at a time rather than
-- extracting `Array Int`s and deferring to the array instances.  Extraction
-- would allocate a boxed word per byte on every comparison, which is the cost
-- the packed representation exists to avoid.

eqGo : ByteBlock -> ByteBlock -> Int -> Int -> Bool
eqGo a b i n =
  if i >= n then
    True
  else if byteBlockGetUnsafe i a == byteBlockGetUnsafe i b then
    eqGo a b (i + 1) n
  else
    False

{- | Two byte strings are equal when they hold the same bytes in the same
   order.

   > eq (fromArrayAssumeByteDomain [|1, 2|]) (fromArrayAssumeByteDomain [|1, 2|])
   True
   > eq (fromArrayAssumeByteDomain [|1, 2|]) (fromArrayAssumeByteDomain [|1, 2, 3|])
   False -}
export impl Eq Bytes where
  eq (Bytes a) (Bytes b) =
    let n = byteBlockLength a
    if n /= byteBlockLength b then False else eqGo a b 0 n

compareGo : ByteBlock -> ByteBlock -> Int -> Int -> Int -> Ordering
compareGo a b i na nb =
  if i >= na then
    if i >= nb then Eq else Lt
  else if i >= nb then
    Gt
  else
    let x = byteBlockGetUnsafe i a
    let y = byteBlockGetUnsafe i b
    if x < y then Lt else if x > y then Gt else compareGo a b (i + 1) na nb

{- | Byte strings compare lexicographically, exactly as the arrays of their
   bytes do: byte by byte from the front, and a prefix sorts before what
   extends it.

   > compare (fromArrayAssumeByteDomain [|1, 2|]) (fromArrayAssumeByteDomain [|1, 3|])
   Lt
   > compare (fromArrayAssumeByteDomain [|1, 2|]) (fromArrayAssumeByteDomain [|1, 2, 0|])
   Lt -}
export impl Ord Bytes where
  compare (Bytes a) (Bytes b) =
    compareGo a b 0 (byteBlockLength a) (byteBlockLength b)

{- | Renders as its bytes would as an `Array Int`.

   > debug (fromArrayAssumeByteDomain [|7, 8, 9|])
   "[|7, 8, 9|]" -}
export impl Debug Bytes where
  debug (Bytes bb) = debug (byteBlockToIntArray bb)

-- # Text

{- | The UTF-8 encoding of `s`.

   A codepoint outside ASCII contributes several bytes, so the byte count is
   at least the codepoint count and often larger.

   > bytesLength (toUtf8Bytes "héllo")
   6 -}
export
toUtf8Bytes : String -> Bytes
toUtf8Bytes s = Bytes (byteBlockFromString s)

{- | The string encoded by `b`, read as UTF-8.

   On valid UTF-8, `fromUtf8Bytes (toUtf8Bytes s)` is `s`.

   > fromUtf8Bytes (toUtf8Bytes "héllo→")
   "héllo→" -}
export
fromUtf8Bytes : Bytes -> String
fromUtf8Bytes (Bytes bb) = stringFromUtf8Bytes (byteBlockToIntArray bb)

-- # Mutation

-- `MutBytes` lives beside `Bytes` rather than in its own module because
-- `freeze` builds a `Bytes` out of a block, and the `Bytes` constructor is
-- module-private: a module elsewhere could only reach it if this one exported
-- a second way in.
--
-- The names carry the type because the module holds two of them and the bare
-- `get` and `length` are already `Bytes`'s.

{- | A mutable string of bytes, fixed at its allocated length.

   The constructor is module-private, so `mutBytesMake` is the way in and
   `freeze` the way out, and nothing observes the buffer except through the
   functions below.

   Reach for it to build a byte string a byte at a time. The alternative --
   filling an `Array Int` and handing it to `fromArray` -- boxes a machine
   word per byte before packing them, which is the cost `Bytes` exists to
   avoid.

   > mutBytesLength (mutBytesMake 3)
   3 -}
export newtype MutBytes = MutBytes ByteBlock

{- | A mutable byte string of `n` zero bytes.

   Panics when `n` is negative.

   > mutBytesGet 2 (mutBytesMake 3)
   Some 0 -}
export
mutBytesMake : Int -> MutBytes
mutBytesMake n =
  if n < 0 then
    panic "MutBytes.mutBytesMake: negative length"
  else
    MutBytes (byteBlockMake n)

{- | The number of bytes in `mb`, fixed when it was allocated.

   > mutBytesLength (mutBytesMake 4)
   4 -}
export
mutBytesLength : MutBytes -> Int
mutBytesLength (MutBytes bb) = byteBlockLength bb

{- | The byte at index `i` of `mb`, or `None` when `i` is out of range.

   > mutBytesGet 1 (mutBytesMake 2)
   Some 0
   > mutBytesGet 2 (mutBytesMake 2)
   None
   > mutBytesGet (-1) (mutBytesMake 2)
   None -}
export
mutBytesGet : Int -> MutBytes -> Option Int
mutBytesGet i (MutBytes bb) =
  if i < 0 || i >= byteBlockLength bb then
    None
  else
    Some (byteBlockGetUnsafe i bb)

{- | Replaces the byte at index `i` of `mb` with `v`.

   Panics when `i` is out of range, as `array.setInPlace` does, and panics
   when `v` falls outside `0` to `255` rather than keeping its low eight
   bits. A masked write would put a byte into a `Bytes` that no caller asked
   for, and this is the door every byte written here goes through.

   > let mb = mutBytesMake 2 in let _ = mutBytesSet 0 65 mb in mutBytesGet 0 mb
   Some 65 -}
export
mutBytesSet : Int -> Int -> MutBytes -> Unit
mutBytesSet i v (MutBytes bb) =
  if v < 0 || v > 255 then
    panic "MutBytes.mutBytesSet: value out of range 0..255"
  else if i < 0 || i >= byteBlockLength bb then
    panic "MutBytes.mutBytesSet: index out of bounds"
  else
    byteBlockSetUnsafe i v bb

{- | The bytes of `mb` as an immutable `Bytes`.

   The result is a copy, so a write to `mb` afterwards does not reach it.

   > let mb = mutBytesMake 2 in let _ = mutBytesSet 1 9 mb in toArray (freeze mb)
   [|0, 9|]
   > let m = mutBytesMake 1 in let b = freeze m in let _ = mutBytesSet 0 7 m in toArray b
   [|0|] -}
export
freeze : MutBytes -> Bytes
freeze (MutBytes bb) = Bytes (byteBlockCopyUnsafe (byteBlockLength bb) bb)
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Ordering" false) (mem "Debug" false) (mem "Option" false) (mem "Index" false))))
(DUse false (UseGroup ("array") ((mem "findIndex" false))))
(DNewtype true "Bytes" () "Bytes" (TyCon "ByteBlock") ())
(DTypeSig true "fromArray" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Bytes"))))
(DFunDef false "fromArray" ((PVar "arr")) (EMatch (EApp (EApp (EVar "findIndex") (ELam ((PVar "b")) (EBinOp "||" (EBinOp "<" (EVar "b") (ELit (LInt 0))) (EBinOp ">" (EVar "b") (ELit (LInt 255)))))) (EVar "arr")) (arm (PCon "Some" PWild) () (EVar "None")) (arm (PCon "None") () (EApp (EVar "Some") (EApp (EVar "Bytes") (EApp (EVar "byteBlockFromIntArray") (EVar "arr")))))))
(DTypeSig true "fromArrayAssumeByteDomain" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Bytes")))
(DFunDef false "fromArrayAssumeByteDomain" ((PVar "arr")) (EApp (EVar "Bytes") (EApp (EVar "byteBlockFromIntArray") (EVar "arr"))))
(DTypeSig true "toArray" (TyFun (TyCon "Bytes") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "toArray" ((PCon "Bytes" (PVar "bb"))) (EApp (EVar "byteBlockToIntArray") (EVar "bb")))
(DTypeSig true "bytesLength" (TyFun (TyCon "Bytes") (TyCon "Int")))
(DFunDef false "bytesLength" ((PCon "Bytes" (PVar "bb"))) (EApp (EVar "byteBlockLength") (EVar "bb")))
(DTypeSig true "get" (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "get" ((PVar "i") (PCon "Bytes" (PVar "bb"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb")))))
(DImpl true "Index" ((TyCon "Bytes") (TyCon "Int") (TyCon "Int")) () ((im "index" ((PCon "Bytes" (PVar "bb")) (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EApp (EVar "indexErrorAt") (EVar "i")) (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb"))))))
(DTypeSig false "eqGo" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "eqGo" ((PVar "a") (PVar "b") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "True") (EIf (EBinOp "==" (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "a")) (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "b"))) (EApp (EApp (EApp (EApp (EVar "eqGo") (EVar "a")) (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "False"))))
(DImpl true "Eq" ((TyCon "Bytes")) () ((im "eq" ((PCon "Bytes" (PVar "a")) (PCon "Bytes" (PVar "b"))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "byteBlockLength") (EVar "a"))) (DoExpr (EIf (EBinOp "/=" (EVar "n") (EApp (EVar "byteBlockLength") (EVar "b"))) (EVar "False") (EApp (EApp (EApp (EApp (EVar "eqGo") (EVar "a")) (EVar "b")) (ELit (LInt 0))) (EVar "n"))))))))
(DTypeSig false "compareGo" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Ordering")))))))
(DFunDef false "compareGo" ((PVar "a") (PVar "b") (PVar "i") (PVar "na") (PVar "nb")) (EIf (EBinOp ">=" (EVar "i") (EVar "na")) (EIf (EBinOp ">=" (EVar "i") (EVar "nb")) (EVar "Eq") (EVar "Lt")) (EIf (EBinOp ">=" (EVar "i") (EVar "nb")) (EVar "Gt") (EBlock (DoLet false false (PVar "x") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "a"))) (DoLet false false (PVar "y") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "b"))) (DoExpr (EIf (EBinOp "<" (EVar "x") (EVar "y")) (EVar "Lt") (EIf (EBinOp ">" (EVar "x") (EVar "y")) (EVar "Gt") (EApp (EApp (EApp (EApp (EApp (EVar "compareGo") (EVar "a")) (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "na")) (EVar "nb")))))))))
(DImpl true "Ord" ((TyCon "Bytes")) () ((im "compare" ((PCon "Bytes" (PVar "a")) (PCon "Bytes" (PVar "b"))) (EApp (EApp (EApp (EApp (EApp (EVar "compareGo") (EVar "a")) (EVar "b")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "a"))) (EApp (EVar "byteBlockLength") (EVar "b"))))))
(DImpl true "Debug" ((TyCon "Bytes")) () ((im "debug" ((PCon "Bytes" (PVar "bb"))) (EApp (EVar "debug") (EApp (EVar "byteBlockToIntArray") (EVar "bb"))))))
(DTypeSig true "toUtf8Bytes" (TyFun (TyCon "String") (TyCon "Bytes")))
(DFunDef false "toUtf8Bytes" ((PVar "s")) (EApp (EVar "Bytes") (EApp (EVar "byteBlockFromString") (EVar "s"))))
(DTypeSig true "fromUtf8Bytes" (TyFun (TyCon "Bytes") (TyCon "String")))
(DFunDef false "fromUtf8Bytes" ((PCon "Bytes" (PVar "bb"))) (EApp (EVar "stringFromUtf8Bytes") (EApp (EVar "byteBlockToIntArray") (EVar "bb"))))
(DNewtype true "MutBytes" () "MutBytes" (TyCon "ByteBlock") ())
(DTypeSig true "mutBytesMake" (TyFun (TyCon "Int") (TyCon "MutBytes")))
(DFunDef false "mutBytesMake" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "MutBytes.mutBytesMake: negative length"))) (EApp (EVar "MutBytes") (EApp (EVar "byteBlockMake") (EVar "n")))))
(DTypeSig true "mutBytesLength" (TyFun (TyCon "MutBytes") (TyCon "Int")))
(DFunDef false "mutBytesLength" ((PCon "MutBytes" (PVar "bb"))) (EApp (EVar "byteBlockLength") (EVar "bb")))
(DTypeSig true "mutBytesGet" (TyFun (TyCon "Int") (TyFun (TyCon "MutBytes") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "mutBytesGet" ((PVar "i") (PCon "MutBytes" (PVar "bb"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb")))))
(DTypeSig true "mutBytesSet" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "MutBytes") (TyCon "Unit")))))
(DFunDef false "mutBytesSet" ((PVar "i") (PVar "v") (PCon "MutBytes" (PVar "bb"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "v") (ELit (LInt 0))) (EBinOp ">" (EVar "v") (ELit (LInt 255)))) (EApp (EVar "panic") (ELit (LString "MutBytes.mutBytesSet: value out of range 0..255"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EApp (EVar "panic") (ELit (LString "MutBytes.mutBytesSet: index out of bounds"))) (EApp (EApp (EApp (EVar "byteBlockSetUnsafe") (EVar "i")) (EVar "v")) (EVar "bb")))))
(DTypeSig true "freeze" (TyFun (TyCon "MutBytes") (TyCon "Bytes")))
(DFunDef false "freeze" ((PCon "MutBytes" (PVar "bb"))) (EApp (EVar "Bytes") (EApp (EApp (EVar "byteBlockCopyUnsafe") (EApp (EVar "byteBlockLength") (EVar "bb"))) (EVar "bb"))))
# MARK
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Ordering" false) (mem "Debug" false) (mem "Option" false) (mem "Index" false))))
(DUse false (UseGroup ("array") ((mem "findIndex" false))))
(DNewtype true "Bytes" () "Bytes" (TyCon "ByteBlock") ())
(DTypeSig true "fromArray" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Bytes"))))
(DFunDef false "fromArray" ((PVar "arr")) (EMatch (EApp (EApp (EVar "findIndex") (ELam ((PVar "b")) (EBinOp "||" (EBinOp "<" (EVar "b") (ELit (LInt 0))) (EBinOp ">" (EVar "b") (ELit (LInt 255)))))) (EVar "arr")) (arm (PCon "Some" PWild) () (EVar "None")) (arm (PCon "None") () (EApp (EVar "Some") (EApp (EVar "Bytes") (EApp (EVar "byteBlockFromIntArray") (EVar "arr")))))))
(DTypeSig true "fromArrayAssumeByteDomain" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Bytes")))
(DFunDef false "fromArrayAssumeByteDomain" ((PVar "arr")) (EApp (EVar "Bytes") (EApp (EVar "byteBlockFromIntArray") (EVar "arr"))))
(DTypeSig true "toArray" (TyFun (TyCon "Bytes") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "toArray" ((PCon "Bytes" (PVar "bb"))) (EApp (EVar "byteBlockToIntArray") (EVar "bb")))
(DTypeSig true "bytesLength" (TyFun (TyCon "Bytes") (TyCon "Int")))
(DFunDef false "bytesLength" ((PCon "Bytes" (PVar "bb"))) (EApp (EVar "byteBlockLength") (EVar "bb")))
(DTypeSig true "get" (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "get" ((PVar "i") (PCon "Bytes" (PVar "bb"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb")))))
(DImpl true "Index" ((TyCon "Bytes") (TyCon "Int") (TyCon "Int")) () ((im "index" ((PCon "Bytes" (PVar "bb")) (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EApp (EVar "indexErrorAt") (EVar "i")) (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb"))))))
(DTypeSig false "eqGo" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "eqGo" ((PVar "a") (PVar "b") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "True") (EIf (EBinOp "==" (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "a")) (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "b"))) (EApp (EApp (EApp (EApp (EDictApp "eqGo") (EVar "a")) (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "False"))))
(DImpl true "Eq" ((TyCon "Bytes")) () ((im "eq" ((PCon "Bytes" (PVar "a")) (PCon "Bytes" (PVar "b"))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "byteBlockLength") (EVar "a"))) (DoExpr (EIf (EBinOp "/=" (EVar "n") (EApp (EVar "byteBlockLength") (EVar "b"))) (EVar "False") (EApp (EApp (EApp (EApp (EDictApp "eqGo") (EVar "a")) (EVar "b")) (ELit (LInt 0))) (EVar "n"))))))))
(DTypeSig false "compareGo" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Ordering")))))))
(DFunDef false "compareGo" ((PVar "a") (PVar "b") (PVar "i") (PVar "na") (PVar "nb")) (EIf (EBinOp ">=" (EVar "i") (EVar "na")) (EIf (EBinOp ">=" (EVar "i") (EVar "nb")) (EVar "Eq") (EVar "Lt")) (EIf (EBinOp ">=" (EVar "i") (EVar "nb")) (EVar "Gt") (EBlock (DoLet false false (PVar "x") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "a"))) (DoLet false false (PVar "y") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "b"))) (DoExpr (EIf (EBinOp "<" (EVar "x") (EVar "y")) (EVar "Lt") (EIf (EBinOp ">" (EVar "x") (EVar "y")) (EVar "Gt") (EApp (EApp (EApp (EApp (EApp (EVar "compareGo") (EVar "a")) (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "na")) (EVar "nb")))))))))
(DImpl true "Ord" ((TyCon "Bytes")) () ((im "compare" ((PCon "Bytes" (PVar "a")) (PCon "Bytes" (PVar "b"))) (EApp (EApp (EApp (EApp (EApp (EVar "compareGo") (EVar "a")) (EVar "b")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "a"))) (EApp (EVar "byteBlockLength") (EVar "b"))))))
(DImpl true "Debug" ((TyCon "Bytes")) () ((im "debug" ((PCon "Bytes" (PVar "bb"))) (EApp (EMethodRef "debug") (EApp (EVar "byteBlockToIntArray") (EVar "bb"))))))
(DTypeSig true "toUtf8Bytes" (TyFun (TyCon "String") (TyCon "Bytes")))
(DFunDef false "toUtf8Bytes" ((PVar "s")) (EApp (EVar "Bytes") (EApp (EVar "byteBlockFromString") (EVar "s"))))
(DTypeSig true "fromUtf8Bytes" (TyFun (TyCon "Bytes") (TyCon "String")))
(DFunDef false "fromUtf8Bytes" ((PCon "Bytes" (PVar "bb"))) (EApp (EVar "stringFromUtf8Bytes") (EApp (EVar "byteBlockToIntArray") (EVar "bb"))))
(DNewtype true "MutBytes" () "MutBytes" (TyCon "ByteBlock") ())
(DTypeSig true "mutBytesMake" (TyFun (TyCon "Int") (TyCon "MutBytes")))
(DFunDef false "mutBytesMake" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "MutBytes.mutBytesMake: negative length"))) (EApp (EVar "MutBytes") (EApp (EVar "byteBlockMake") (EVar "n")))))
(DTypeSig true "mutBytesLength" (TyFun (TyCon "MutBytes") (TyCon "Int")))
(DFunDef false "mutBytesLength" ((PCon "MutBytes" (PVar "bb"))) (EApp (EVar "byteBlockLength") (EVar "bb")))
(DTypeSig true "mutBytesGet" (TyFun (TyCon "Int") (TyFun (TyCon "MutBytes") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "mutBytesGet" ((PVar "i") (PCon "MutBytes" (PVar "bb"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb")))))
(DTypeSig true "mutBytesSet" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "MutBytes") (TyCon "Unit")))))
(DFunDef false "mutBytesSet" ((PVar "i") (PVar "v") (PCon "MutBytes" (PVar "bb"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "v") (ELit (LInt 0))) (EBinOp ">" (EVar "v") (ELit (LInt 255)))) (EApp (EVar "panic") (ELit (LString "MutBytes.mutBytesSet: value out of range 0..255"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EApp (EVar "panic") (ELit (LString "MutBytes.mutBytesSet: index out of bounds"))) (EApp (EApp (EApp (EVar "byteBlockSetUnsafe") (EVar "i")) (EVar "v")) (EVar "bb")))))
(DTypeSig true "freeze" (TyFun (TyCon "MutBytes") (TyCon "Bytes")))
(DFunDef false "freeze" ((PCon "MutBytes" (PVar "bb"))) (EApp (EVar "Bytes") (EApp (EApp (EVar "byteBlockCopyUnsafe") (EApp (EVar "byteBlockLength") (EVar "bb"))) (EVar "bb"))))
