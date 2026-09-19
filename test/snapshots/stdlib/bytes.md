# META
source_lines=480
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
   `Option`-returning form. `slice` copies out a sub-range and panics on a
   range that runs outside the byte string, and `indexOf` finds the first
   byte equal to a given value. Two byte strings compare lexicographically,
   as the arrays of their bytes do, and hash as the arrays of their bytes do,
   so `Bytes` is a `HashMap`/`HashSet` key.

   `append` joins two byte strings, and `b1 ++ b2` reaches it: `++` is
   `Semigroup`'s `append`, so it dispatches on `Bytes` and allocates the
   joined length once. Applied where the operand type is known -- infix, in
   a section, or under a `Semigroup` constraint -- it dispatches. Bound to a
   name first, as `let f = (++)` or `let f = (x y => x ++ y)`, it does not:
   it falls through to the runtime's untyped concatenation, which has no
   byte-buffer case, and fails at run time. Bind `append` instead, which
   dispatches from either position.

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
--
-- The round-trip that shows a byte string really keys a hash container lives
-- in `test/engine_fixtures/bytes_hashmap_key.mdk`, not in a doctest on the
-- `Hashable Bytes` instance.  That doctest would have to import the
-- hash-container module, and an import here reaches every module that imports
-- this one: it would drag that module's `Ref` internals into their builds,
-- which the wasm backend cannot assemble, and cost them work they spend on
-- nothing they use.
--
-- The `++` gap the module doc describes is issue #3204: a `let`-bound `++`
-- reaches the runtime's untyped concatenation instead of this module's
-- `Semigroup` instance.  It dispatches from infix position, an operator
-- section, an immediately applied lambda, a signature-carrying function body,
-- and a `Semigroup a =>` constrained body.  It does not from `let f = (++)`
-- or `let f = (x y => x ++ y)`, the latter even when a later annotated call
-- site pins the operand type.  `append` bound to a name dispatches, which is
-- why the doc points a caller at it.

import core.{
  Eq, Ord, Ordering, Debug, Option, Index, Slice, Semigroup, Hashable
}
import array.{findIndex}

{- | The byte-string type.

   The constructor is module-private, so `fromArray`,
   `fromArrayAssumeByteDomain`, `fromByteBlockPrefix` and `toUtf8Bytes` are
   the ways in and `toArray` and `fromUtf8Bytes` are the ways out.

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
   construction move to `Bytes` without paying a scan, and it is removed once
   the domain-checked door is the only one, alongside `toUtf8`/`fromUtf8`.

   > toArray (fromArrayAssumeByteDomain [|104, 105|])
   [|104, 105|]
   > toArray (fromArrayAssumeByteDomain [|300, -1|])
   [|44, 255|] -}
export
fromArrayAssumeByteDomain : Array Int -> Bytes
fromArrayAssumeByteDomain arr = Bytes (byteBlockFromIntArray arr)

{- | The first `n` bytes of `bb`, copied into a byte string.

   No domain check runs and none is needed: a `ByteBlock` holds one byte per
   element, so every element is already `0` to `255`. `fromArray` scans
   because an `Array Int` element can be anything.

   The result is a copy, so a later write to `bb` does not reach it. This is
   how a growable byte buffer freezes its live prefix -- `bytebuilder`'s
   `buildBytes` is the caller -- which is why it takes a length rather than
   the whole block.

   Panics when `n` falls outside `0` to the block's length.

   > toArray (fromByteBlockPrefix 2 (byteBlockFromString "hip"))
   [|104, 105|] -}
export
fromByteBlockPrefix : Int -> ByteBlock -> Bytes
fromByteBlockPrefix n bb =
  if n < 0 || n > byteBlockLength bb then
    panic "Bytes.fromByteBlockPrefix: length out of range"
  else
    Bytes (byteBlockCopyUnsafe n bb)

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

{- | The bytes over `[lo, hi)`, copied into a new byte string. The
   `b.[lo..hi]` and `b.[lo..=hi]` syntax dispatches here.

   The result is a copy, not a view onto `b`: a byte string is `n` bytes and
   nothing more, so there is no offset and length to share one with.

   Panics with a slice error when the range runs outside the byte string,
   exactly as `Slice (Array a)` does.

   > toArray (slice (fromArrayAssumeByteDomain [|10, 20, 30, 40, 50|]) 1 3)
   [|20, 30|]
   > toArray (slice (fromArrayAssumeByteDomain [|10, 20|]) 1 1)
   [||] -}
export impl Slice Bytes where
  slice (Bytes bb) lo hi =
    if lo < 0 || hi > byteBlockLength bb || hi - lo < 0 then
      sliceError lo (hi - 1)
    else
      let dst = byteBlockMake (hi - lo)
      let _ = byteBlockBlit bb lo dst 0 (hi - lo)
      Bytes dst

indexOfGo : Int -> ByteBlock -> Int -> Int -> Option Int
indexOfGo v bb i n =
  if i >= n then
    None
  else if byteBlockGetUnsafe i bb == v then
    Some i
  else
    indexOfGo v bb (i + 1) n

{- | The index of the first byte equal to `v`, or `None` when no byte is.

   The needle is one byte, where `string.indexOf` takes a whole substring:
   `Bytes` is a sequence of byte values, and this is the search for one of
   them, as `list.elemIndex` is for a list element. A `v` outside `0` to
   `255` equals no byte, so the answer is `None`.

   > indexOf 9 (fromArrayAssumeByteDomain [|7, 9, 8, 9|])
   Some 1
   > indexOf 5 (fromArrayAssumeByteDomain [|7, 9, 8|])
   None
   > indexOf 300 (fromArrayAssumeByteDomain [|7, 9, 8|])
   None -}
export
indexOf : Int -> Bytes -> Option Int
indexOf v (Bytes bb) = indexOfGo v bb 0 (byteBlockLength bb)

-- # Combining

{- | The bytes of `b1` followed by the bytes of `b2`, in a new byte string.
   Backs `++`.

   > toArray (append (fromArrayAssumeByteDomain [|1, 2|]) (fromArrayAssumeByteDomain [|3|]))
   [|1, 2, 3|]
   > fromUtf8Bytes (toUtf8Bytes "hé" ++ toUtf8Bytes "llo")
   "héllo" -}
export impl Semigroup Bytes where
  append (Bytes a) (Bytes b) =
    let na = byteBlockLength a
    let nb = byteBlockLength b
    let dst = byteBlockMake (na + nb)
    let _ = byteBlockBlit a 0 dst 0 na
    let _ = byteBlockBlit b 0 dst na nb
    Bytes dst

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

hashGo : Int -> ByteBlock -> Int -> Int -> Int
hashGo acc bb i n =
  if i >= n then
    acc
  else
    hashGo (acc * 33 + hashInt (byteBlockGetUnsafe i bb)) bb (i + 1) n

{- | The `acc * 33 + hash byte` fold `Hashable (Array a)` runs over elements,
   from `0` and left to right, so a byte string hashes as the `Array Int` or
   `List Int` of its bytes does. `hashInt` is what `Hashable Int` would
   contribute for each byte. Agrees with `Eq Bytes`, which walks the same
   bytes in the same order.

   > hash (fromArrayAssumeByteDomain [|1, 2, 3|]) == hash [|1, 2, 3|]
   True -}
export impl Hashable Bytes where
  hash (Bytes bb) = hashGo 0 bb 0 (byteBlockLength bb)

-- The rendering walks the block a byte at a time, mirroring
-- `core.debugArrayItems` by index, rather than rendering the `Array Int` of
-- the bytes: the array would box a machine word per byte to produce the same
-- characters.
debugBytesItems : ByteBlock -> Int -> Int -> String
debugBytesItems bb i n
  | i >= n = ""
  | i == n - 1 = debug (byteBlockGetUnsafe i bb)
  | otherwise =
    "\{debug (byteBlockGetUnsafe i bb)}, \{debugBytesItems bb (i + 1) n}"

{- | Renders as its bytes would as an `Array Int`.

   > debug (fromArrayAssumeByteDomain [|7, 8, 9|])
   "[|7, 8, 9|]"
   > debug (fromArrayAssumeByteDomain [||])
   "[||]" -}
export impl Debug Bytes where
  debug (Bytes bb) = "[|\{debugBytesItems bb 0 (byteBlockLength bb)}|]"

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
fromUtf8Bytes (Bytes bb) = byteBlockToString bb

-- # Output

{- | Writes `b`'s bytes to standard output byte-for-byte.

   Unlike `putStr`, the bytes are not required to be valid UTF-8: nothing
   here decodes or re-encodes them, so a byte sequence that would mangle or
   get rejected on a `String` path round-trips exactly. -}
export
writeStdoutBytes : Bytes -> <Stdout> Unit
writeStdoutBytes (Bytes bb) = byteBlockWriteStdout bb

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
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Ordering" false) (mem "Debug" false) (mem "Option" false) (mem "Index" false) (mem "Slice" false) (mem "Semigroup" false) (mem "Hashable" false))))
(DUse false (UseGroup ("array") ((mem "findIndex" false))))
(DNewtype true "Bytes" () "Bytes" (TyCon "ByteBlock") ())
(DTypeSig true "fromArray" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Bytes"))))
(DFunDef false "fromArray" ((PVar "arr")) (EMatch (EApp (EApp (EVar "findIndex") (ELam ((PVar "b")) (EBinOp "||" (EBinOp "<" (EVar "b") (ELit (LInt 0))) (EBinOp ">" (EVar "b") (ELit (LInt 255)))))) (EVar "arr")) (arm (PCon "Some" PWild) () (EVar "None")) (arm (PCon "None") () (EApp (EVar "Some") (EApp (EVar "Bytes") (EApp (EVar "byteBlockFromIntArray") (EVar "arr")))))))
(DTypeSig true "fromArrayAssumeByteDomain" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Bytes")))
(DFunDef false "fromArrayAssumeByteDomain" ((PVar "arr")) (EApp (EVar "Bytes") (EApp (EVar "byteBlockFromIntArray") (EVar "arr"))))
(DTypeSig true "fromByteBlockPrefix" (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyCon "Bytes"))))
(DFunDef false "fromByteBlockPrefix" ((PVar "n") (PVar "bb")) (EIf (EBinOp "||" (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp ">" (EVar "n") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EApp (EVar "panic") (ELit (LString "Bytes.fromByteBlockPrefix: length out of range"))) (EApp (EVar "Bytes") (EApp (EApp (EVar "byteBlockCopyUnsafe") (EVar "n")) (EVar "bb")))))
(DTypeSig true "toArray" (TyFun (TyCon "Bytes") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "toArray" ((PCon "Bytes" (PVar "bb"))) (EApp (EVar "byteBlockToIntArray") (EVar "bb")))
(DTypeSig true "bytesLength" (TyFun (TyCon "Bytes") (TyCon "Int")))
(DFunDef false "bytesLength" ((PCon "Bytes" (PVar "bb"))) (EApp (EVar "byteBlockLength") (EVar "bb")))
(DTypeSig true "get" (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "get" ((PVar "i") (PCon "Bytes" (PVar "bb"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb")))))
(DImpl true "Index" ((TyCon "Bytes") (TyCon "Int") (TyCon "Int")) () ((im "index" ((PCon "Bytes" (PVar "bb")) (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EApp (EVar "indexErrorAt") (EVar "i")) (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb"))))))
(DImpl true "Slice" ((TyCon "Bytes")) () ((im "slice" ((PCon "Bytes" (PVar "bb")) (PVar "lo") (PVar "hi")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (EBinOp ">" (EVar "hi") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EBinOp "<" (EBinOp "-" (EVar "hi") (EVar "lo")) (ELit (LInt 0)))) (EApp (EApp (EVar "sliceError") (EVar "lo")) (EBinOp "-" (EVar "hi") (ELit (LInt 1)))) (EBlock (DoLet false false (PVar "dst") (EApp (EVar "byteBlockMake") (EBinOp "-" (EVar "hi") (EVar "lo")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "bb")) (EVar "lo")) (EVar "dst")) (ELit (LInt 0))) (EBinOp "-" (EVar "hi") (EVar "lo")))) (DoExpr (EApp (EVar "Bytes") (EVar "dst"))))))))
(DTypeSig false "indexOfGo" (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "indexOfGo" ((PVar "v") (PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb")) (EVar "v")) (EApp (EVar "Some") (EVar "i")) (EApp (EApp (EApp (EApp (EVar "indexOfGo") (EVar "v")) (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig true "indexOf" (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "indexOf" ((PVar "v") (PCon "Bytes" (PVar "bb"))) (EApp (EApp (EApp (EApp (EVar "indexOfGo") (EVar "v")) (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))))
(DImpl true "Semigroup" ((TyCon "Bytes")) () ((im "append" ((PCon "Bytes" (PVar "a")) (PCon "Bytes" (PVar "b"))) (EBlock (DoLet false false (PVar "na") (EApp (EVar "byteBlockLength") (EVar "a"))) (DoLet false false (PVar "nb") (EApp (EVar "byteBlockLength") (EVar "b"))) (DoLet false false (PVar "dst") (EApp (EVar "byteBlockMake") (EBinOp "+" (EVar "na") (EVar "nb")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "a")) (ELit (LInt 0))) (EVar "dst")) (ELit (LInt 0))) (EVar "na"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "b")) (ELit (LInt 0))) (EVar "dst")) (EVar "na")) (EVar "nb"))) (DoExpr (EApp (EVar "Bytes") (EVar "dst")))))))
(DTypeSig false "eqGo" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "eqGo" ((PVar "a") (PVar "b") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "True") (EIf (EBinOp "==" (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "a")) (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "b"))) (EApp (EApp (EApp (EApp (EVar "eqGo") (EVar "a")) (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "False"))))
(DImpl true "Eq" ((TyCon "Bytes")) () ((im "eq" ((PCon "Bytes" (PVar "a")) (PCon "Bytes" (PVar "b"))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "byteBlockLength") (EVar "a"))) (DoExpr (EIf (EBinOp "/=" (EVar "n") (EApp (EVar "byteBlockLength") (EVar "b"))) (EVar "False") (EApp (EApp (EApp (EApp (EVar "eqGo") (EVar "a")) (EVar "b")) (ELit (LInt 0))) (EVar "n"))))))))
(DTypeSig false "compareGo" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Ordering")))))))
(DFunDef false "compareGo" ((PVar "a") (PVar "b") (PVar "i") (PVar "na") (PVar "nb")) (EIf (EBinOp ">=" (EVar "i") (EVar "na")) (EIf (EBinOp ">=" (EVar "i") (EVar "nb")) (EVar "Eq") (EVar "Lt")) (EIf (EBinOp ">=" (EVar "i") (EVar "nb")) (EVar "Gt") (EBlock (DoLet false false (PVar "x") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "a"))) (DoLet false false (PVar "y") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "b"))) (DoExpr (EIf (EBinOp "<" (EVar "x") (EVar "y")) (EVar "Lt") (EIf (EBinOp ">" (EVar "x") (EVar "y")) (EVar "Gt") (EApp (EApp (EApp (EApp (EApp (EVar "compareGo") (EVar "a")) (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "na")) (EVar "nb")))))))))
(DImpl true "Ord" ((TyCon "Bytes")) () ((im "compare" ((PCon "Bytes" (PVar "a")) (PCon "Bytes" (PVar "b"))) (EApp (EApp (EApp (EApp (EApp (EVar "compareGo") (EVar "a")) (EVar "b")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "a"))) (EApp (EVar "byteBlockLength") (EVar "b"))))))
(DTypeSig false "hashGo" (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "hashGo" ((PVar "acc") (PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EApp (EApp (EApp (EApp (EVar "hashGo") (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 33))) (EApp (EVar "hashInt") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb"))))) (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))))
(DImpl true "Hashable" ((TyCon "Bytes")) () ((im "hash" ((PCon "Bytes" (PVar "bb"))) (EApp (EApp (EApp (EApp (EVar "hashGo") (ELit (LInt 0))) (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))))))
(DTypeSig false "debugBytesItems" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "debugBytesItems" ((PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit (LString "")) (EIf (EBinOp "==" (EVar "i") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EVar "debug") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "debug") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb"))))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "debugBytesItems") (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))) (ELit (LString ""))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DImpl true "Debug" ((TyCon "Bytes")) () ((im "debug" ((PCon "Bytes" (PVar "bb"))) (EBinOp "++" (EBinOp "++" (ELit (LString "[|")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "debugBytesItems") (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))))) (ELit (LString "|]"))))))
(DTypeSig true "toUtf8Bytes" (TyFun (TyCon "String") (TyCon "Bytes")))
(DFunDef false "toUtf8Bytes" ((PVar "s")) (EApp (EVar "Bytes") (EApp (EVar "byteBlockFromString") (EVar "s"))))
(DTypeSig true "fromUtf8Bytes" (TyFun (TyCon "Bytes") (TyCon "String")))
(DFunDef false "fromUtf8Bytes" ((PCon "Bytes" (PVar "bb"))) (EApp (EVar "byteBlockToString") (EVar "bb")))
(DTypeSig true "writeStdoutBytes" (TyFun (TyCon "Bytes") (TyEffect ("Stdout") None (TyCon "Unit"))))
(DFunDef false "writeStdoutBytes" ((PCon "Bytes" (PVar "bb"))) (EApp (EVar "byteBlockWriteStdout") (EVar "bb")))
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
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Ordering" false) (mem "Debug" false) (mem "Option" false) (mem "Index" false) (mem "Slice" false) (mem "Semigroup" false) (mem "Hashable" false))))
(DUse false (UseGroup ("array") ((mem "findIndex" false))))
(DNewtype true "Bytes" () "Bytes" (TyCon "ByteBlock") ())
(DTypeSig true "fromArray" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Bytes"))))
(DFunDef false "fromArray" ((PVar "arr")) (EMatch (EApp (EApp (EVar "findIndex") (ELam ((PVar "b")) (EBinOp "||" (EBinOp "<" (EVar "b") (ELit (LInt 0))) (EBinOp ">" (EVar "b") (ELit (LInt 255)))))) (EVar "arr")) (arm (PCon "Some" PWild) () (EVar "None")) (arm (PCon "None") () (EApp (EVar "Some") (EApp (EVar "Bytes") (EApp (EVar "byteBlockFromIntArray") (EVar "arr")))))))
(DTypeSig true "fromArrayAssumeByteDomain" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Bytes")))
(DFunDef false "fromArrayAssumeByteDomain" ((PVar "arr")) (EApp (EVar "Bytes") (EApp (EVar "byteBlockFromIntArray") (EVar "arr"))))
(DTypeSig true "fromByteBlockPrefix" (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyCon "Bytes"))))
(DFunDef false "fromByteBlockPrefix" ((PVar "n") (PVar "bb")) (EIf (EBinOp "||" (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp ">" (EVar "n") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EApp (EVar "panic") (ELit (LString "Bytes.fromByteBlockPrefix: length out of range"))) (EApp (EVar "Bytes") (EApp (EApp (EVar "byteBlockCopyUnsafe") (EVar "n")) (EVar "bb")))))
(DTypeSig true "toArray" (TyFun (TyCon "Bytes") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "toArray" ((PCon "Bytes" (PVar "bb"))) (EApp (EVar "byteBlockToIntArray") (EVar "bb")))
(DTypeSig true "bytesLength" (TyFun (TyCon "Bytes") (TyCon "Int")))
(DFunDef false "bytesLength" ((PCon "Bytes" (PVar "bb"))) (EApp (EVar "byteBlockLength") (EVar "bb")))
(DTypeSig true "get" (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "get" ((PVar "i") (PCon "Bytes" (PVar "bb"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb")))))
(DImpl true "Index" ((TyCon "Bytes") (TyCon "Int") (TyCon "Int")) () ((im "index" ((PCon "Bytes" (PVar "bb")) (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EApp (EVar "indexErrorAt") (EVar "i")) (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb"))))))
(DImpl true "Slice" ((TyCon "Bytes")) () ((im "slice" ((PCon "Bytes" (PVar "bb")) (PVar "lo") (PVar "hi")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (EBinOp ">" (EVar "hi") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EBinOp "<" (EBinOp "-" (EVar "hi") (EVar "lo")) (ELit (LInt 0)))) (EApp (EApp (EVar "sliceError") (EVar "lo")) (EBinOp "-" (EVar "hi") (ELit (LInt 1)))) (EBlock (DoLet false false (PVar "dst") (EApp (EVar "byteBlockMake") (EBinOp "-" (EVar "hi") (EVar "lo")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "bb")) (EVar "lo")) (EVar "dst")) (ELit (LInt 0))) (EBinOp "-" (EVar "hi") (EVar "lo")))) (DoExpr (EApp (EVar "Bytes") (EVar "dst"))))))))
(DTypeSig false "indexOfGo" (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "indexOfGo" ((PVar "v") (PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb")) (EVar "v")) (EApp (EVar "Some") (EVar "i")) (EApp (EApp (EApp (EApp (EVar "indexOfGo") (EVar "v")) (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig true "indexOf" (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "indexOf" ((PVar "v") (PCon "Bytes" (PVar "bb"))) (EApp (EApp (EApp (EApp (EVar "indexOfGo") (EVar "v")) (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))))
(DImpl true "Semigroup" ((TyCon "Bytes")) () ((im "append" ((PCon "Bytes" (PVar "a")) (PCon "Bytes" (PVar "b"))) (EBlock (DoLet false false (PVar "na") (EApp (EVar "byteBlockLength") (EVar "a"))) (DoLet false false (PVar "nb") (EApp (EVar "byteBlockLength") (EVar "b"))) (DoLet false false (PVar "dst") (EApp (EVar "byteBlockMake") (EBinOp "+" (EVar "na") (EVar "nb")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "a")) (ELit (LInt 0))) (EVar "dst")) (ELit (LInt 0))) (EVar "na"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "b")) (ELit (LInt 0))) (EVar "dst")) (EVar "na")) (EVar "nb"))) (DoExpr (EApp (EVar "Bytes") (EVar "dst")))))))
(DTypeSig false "eqGo" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "eqGo" ((PVar "a") (PVar "b") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "True") (EIf (EBinOp "==" (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "a")) (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "b"))) (EApp (EApp (EApp (EApp (EDictApp "eqGo") (EVar "a")) (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "False"))))
(DImpl true "Eq" ((TyCon "Bytes")) () ((im "eq" ((PCon "Bytes" (PVar "a")) (PCon "Bytes" (PVar "b"))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "byteBlockLength") (EVar "a"))) (DoExpr (EIf (EBinOp "/=" (EVar "n") (EApp (EVar "byteBlockLength") (EVar "b"))) (EVar "False") (EApp (EApp (EApp (EApp (EDictApp "eqGo") (EVar "a")) (EVar "b")) (ELit (LInt 0))) (EVar "n"))))))))
(DTypeSig false "compareGo" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Ordering")))))))
(DFunDef false "compareGo" ((PVar "a") (PVar "b") (PVar "i") (PVar "na") (PVar "nb")) (EIf (EBinOp ">=" (EVar "i") (EVar "na")) (EIf (EBinOp ">=" (EVar "i") (EVar "nb")) (EVar "Eq") (EVar "Lt")) (EIf (EBinOp ">=" (EVar "i") (EVar "nb")) (EVar "Gt") (EBlock (DoLet false false (PVar "x") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "a"))) (DoLet false false (PVar "y") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "b"))) (DoExpr (EIf (EBinOp "<" (EVar "x") (EVar "y")) (EVar "Lt") (EIf (EBinOp ">" (EVar "x") (EVar "y")) (EVar "Gt") (EApp (EApp (EApp (EApp (EApp (EVar "compareGo") (EVar "a")) (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "na")) (EVar "nb")))))))))
(DImpl true "Ord" ((TyCon "Bytes")) () ((im "compare" ((PCon "Bytes" (PVar "a")) (PCon "Bytes" (PVar "b"))) (EApp (EApp (EApp (EApp (EApp (EVar "compareGo") (EVar "a")) (EVar "b")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "a"))) (EApp (EVar "byteBlockLength") (EVar "b"))))))
(DTypeSig false "hashGo" (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "hashGo" ((PVar "acc") (PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EApp (EApp (EApp (EApp (EVar "hashGo") (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 33))) (EApp (EVar "hashInt") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb"))))) (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))))
(DImpl true "Hashable" ((TyCon "Bytes")) () ((im "hash" ((PCon "Bytes" (PVar "bb"))) (EApp (EApp (EApp (EApp (EVar "hashGo") (ELit (LInt 0))) (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))))))
(DTypeSig false "debugBytesItems" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "debugBytesItems" ((PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit (LString "")) (EIf (EBinOp "==" (EVar "i") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EMethodRef "debug") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb"))))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "debugBytesItems") (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))) (ELit (LString ""))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DImpl true "Debug" ((TyCon "Bytes")) () ((im "debug" ((PCon "Bytes" (PVar "bb"))) (EBinOp "++" (EBinOp "++" (ELit (LString "[|")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "debugBytesItems") (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))))) (ELit (LString "|]"))))))
(DTypeSig true "toUtf8Bytes" (TyFun (TyCon "String") (TyCon "Bytes")))
(DFunDef false "toUtf8Bytes" ((PVar "s")) (EApp (EVar "Bytes") (EApp (EVar "byteBlockFromString") (EVar "s"))))
(DTypeSig true "fromUtf8Bytes" (TyFun (TyCon "Bytes") (TyCon "String")))
(DFunDef false "fromUtf8Bytes" ((PCon "Bytes" (PVar "bb"))) (EApp (EVar "byteBlockToString") (EVar "bb")))
(DTypeSig true "writeStdoutBytes" (TyFun (TyCon "Bytes") (TyEffect ("Stdout") None (TyCon "Unit"))))
(DFunDef false "writeStdoutBytes" ((PCon "Bytes" (PVar "bb"))) (EApp (EVar "byteBlockWriteStdout") (EVar "bb")))
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
