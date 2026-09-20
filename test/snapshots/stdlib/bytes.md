# META
source_lines=747
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
   range that runs outside the byte string, `sliceClamped` clamps the range
   instead, and `indexOf` finds the first
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
import array.{findIndex, fromList}
import string.{toDigit}

{- | The byte-string type.

   The constructor is module-private, so `fromArray`,
   `fromArrayAssumeByteDomain`, `fromByteBlockPrefix`, `adoptByteBlockUnsafe`
   and `encodeUtf8` are the ways in and `toArray`, `lendByteBlockUnsafe`,
   `decodeUtf8` and `decodeUtf8Lossy` are the ways out. The three named here
   with a `ByteBlock` in their signature are the kernel doors, gathered in
   the `# Kernel doors` section at the end of this module.

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

{- | The bytes of `b` as an array, in order.

   > toArray (encodeUtf8 "hi")
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

   > bytesLength (encodeUtf8 "héllo")
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

{- | The bytes over `[lo, hi)`, copied into a new byte string, with both
   bounds clamped into the byte string.

   `slice`'s non-panicking form, and `array.sliceClamped`'s counterpart: a
   range running outside `b` yields a shorter byte string, or an empty one,
   where `b.[lo..hi]` raises a slice error.

   > toArray (sliceClamped 1 3 (fromArrayAssumeByteDomain [|10, 20, 30, 40|]))
   [|20, 30|]
   > toArray (sliceClamped (-5) 99 (fromArrayAssumeByteDomain [|10, 20|]))
   [|10, 20|]
   > toArray (sliceClamped 3 1 (fromArrayAssumeByteDomain [|10, 20|]))
   [||] -}
export
sliceClamped : Int -> Int -> Bytes -> Bytes
sliceClamped lo hi (Bytes bb) =
  let n = byteBlockLength bb
  let lo' = if lo < 0 then 0 else min lo n
  let hi' = if hi < lo' then lo' else min hi n
  let dst = byteBlockMake (hi' - lo')
  let _ = byteBlockBlit bb lo' dst 0 (hi' - lo')
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
   > decodeUtf8 (encodeUtf8 "hé" ++ encodeUtf8 "llo")
   Some "héllo" -}
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

-- `hex.mdk` has an encoder already, but importing it here would cycle: it
-- imports `bytes` for `Bytes` itself. This walks the block a byte at a time,
-- mirroring `core.debugArrayItems` by index rather than rendering the
-- `Array Int` of the bytes, which would box a machine word per byte to
-- produce the same characters.
hexDigit : Int -> Char
hexDigit n = match toDigit n
  Some c => c
  None => '?'

debugBytesHex : ByteBlock -> Int -> Int -> String
debugBytesHex bb i n
  | i >= n = ""
  | otherwise =
    let b = byteBlockGetUnsafe i bb
    "\{hexDigit (shiftRight b 4)}\{hexDigit (bitAnd b 15)}\{debugBytesHex bb (i + 1) n}"

{- | Renders as `Bytes "<hex>"` -- lowercase, two digits per byte, no
   separator between bytes. Distinct from `debug` of the equivalent
   `Array Int`, so a `debug` dump always tells a byte string apart from an
   array of the same numbers.

   > debug (fromArrayAssumeByteDomain [|7, 8, 9|])
   "Bytes \"070809\""
   > debug (fromArrayAssumeByteDomain [||])
   "Bytes \"\""
   > debug (encodeUtf8 "hi") /= debug [|104, 105|]
   True
   > debug (fromArrayAssumeByteDomain (fromList [0..=31]))
   "Bytes \"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\"" -}
export impl Debug Bytes where
  debug (Bytes bb) = "Bytes \"\{debugBytesHex bb 0 (byteBlockLength bb)}\""

-- # Text

{- | The UTF-8 encoding of `s`.

   A codepoint outside ASCII contributes several bytes, so the byte count is
   at least the codepoint count and often larger.

   > bytesLength (encodeUtf8 "héllo")
   6 -}
export
encodeUtf8 : String -> Bytes
encodeUtf8 s = Bytes (byteBlockFromString s)

-- Decoding validates before it hands any bytes to `byteBlockToString`, which
-- blits them into a `String` cell without reading them.  A `String` built
-- from bytes that are not UTF-8 is a value whose own invariants rule out its
-- contents: the cell caches a codepoint count computed by counting
-- non-continuation bytes, so `length`, `toChars` and every renderer answer
-- from it and disagree with the bytes.
--
-- The rules below are `mdk_utf8_is_valid` in `runtime/medaka_rt.c`, which is
-- what the runtime applies to bytes crossing the FFI boundary: `C0`/`C1` and
-- `F5` upwards are not lead bytes, an `E0` or `F0` lead bounds its second
-- byte below to refuse an overlong form, `ED` bounds its second byte above to
-- refuse a surrogate, `F4` bounds its second byte above to refuse anything
-- past U+10FFFF, and a sequence running off the end is truncated.

utf8Continuation : ByteBlock -> Int -> Bool
utf8Continuation bb i =
  let b = byteBlockGetUnsafe i bb
  b >= 0x80 && b <= 0xbf

-- `utf8StepAt` answers the byte length of the well-formed sequence at an
-- offset, or the negation of the maximal subpart of an ill-formed one, so a
-- single `Int` carries both the verdict and how far the scan advances.
-- `utf8Ill k` builds the second form, and a caller reads it back as `0 -
-- step`.  The maximal subpart is what WHATWG substitutes one U+FFFD for: the
-- bytes already accepted when the sequence failed, and one byte when it
-- failed on its lead.
utf8Ill : Int -> Int
utf8Ill k = 0 - k

utf8StepThree : ByteBlock -> Int -> Int -> Int -> Int
utf8StepThree bb i n b0 =
  if i + 1 >= n then
    utf8Ill 1
  else
    let b1 = byteBlockGetUnsafe (i + 1) bb
    let b1Ok =
      if b0 == 0xe0 then
        b1 >= 0xa0 && b1 <= 0xbf
      else if b0 == 0xed then
        b1 >= 0x80 && b1 <= 0x9f
      else
        b1 >= 0x80 && b1 <= 0xbf
    if not b1Ok then
      utf8Ill 1
    else if i + 2 >= n || not (utf8Continuation bb (i + 2)) then
      utf8Ill 2
    else
      3

utf8StepFour : ByteBlock -> Int -> Int -> Int -> Int
utf8StepFour bb i n b0 =
  if i + 1 >= n then
    utf8Ill 1
  else
    let b1 = byteBlockGetUnsafe (i + 1) bb
    let b1Ok =
      if b0 == 0xf0 then
        b1 >= 0x90 && b1 <= 0xbf
      else if b0 == 0xf4 then
        b1 >= 0x80 && b1 <= 0x8f
      else
        b1 >= 0x80 && b1 <= 0xbf
    if not b1Ok then
      utf8Ill 1
    else if i + 2 >= n || not (utf8Continuation bb (i + 2)) then
      utf8Ill 2
    else if i + 3 >= n || not (utf8Continuation bb (i + 3)) then
      utf8Ill 3
    else
      4

utf8StepAt : ByteBlock -> Int -> Int -> Int
utf8StepAt bb i n =
  let b0 = byteBlockGetUnsafe i bb
  if b0 <= 0x7f then
    1
  else if b0 >= 0xc2 && b0 <= 0xdf then
    if i + 1 < n && utf8Continuation bb (i + 1) then 2 else utf8Ill 1
  else if b0 >= 0xe0 && b0 <= 0xef then
    utf8StepThree bb i n b0
  else if b0 >= 0xf0 && b0 <= 0xf4 then
    utf8StepFour bb i n b0
  else
    utf8Ill 1

utf8ValidFrom : ByteBlock -> Int -> Int -> Bool
utf8ValidFrom bb i n =
  if i >= n then
    True
  else
    let step = utf8StepAt bb i n
    step > 0 && utf8ValidFrom bb (i + step) n

{- | The string `b` encodes, read as UTF-8, or `None` when `b` is not valid
   UTF-8.

   The door out of `Bytes` and into `String`. It refuses every byte sequence
   that is not a canonical UTF-8 encoding of Unicode scalar values: an
   unexpected continuation byte, a truncated sequence, an overlong form, a
   surrogate, and anything above U+10FFFF. `decodeUtf8Lossy` is the form that
   substitutes U+FFFD for each of those instead of refusing.

   `decodeUtf8 (encodeUtf8 s)` is `Some s` for every `s`.

   > decodeUtf8 (encodeUtf8 "héllo→")
   Some "héllo→"
   > decodeUtf8 (fromArrayAssumeByteDomain [|0xff, 0xfe, 104, 105|])
   None
   > decodeUtf8 (fromArrayAssumeByteDomain [|0xe2, 0x82|])
   None -}
export
decodeUtf8 : Bytes -> Option String
decodeUtf8 (Bytes bb) =
  if utf8ValidFrom bb 0 (byteBlockLength bb) then
    Some (byteBlockToString bb)
  else
    None

lossyLength : ByteBlock -> Int -> Int -> Int -> Int
lossyLength bb i n acc =
  if i >= n then
    acc
  else
    let step = utf8StepAt bb i n
    if step > 0 then
      lossyLength bb (i + step) n (acc + step)
    else
      lossyLength bb (i + (0 - step)) n (acc + 3)

lossyFill : ByteBlock -> Int -> Int -> ByteBlock -> Int -> Unit
lossyFill bb i n dst j =
  if i >= n then
    ()
  else
    let step = utf8StepAt bb i n
    if step > 0 then
      let _ = byteBlockBlit bb i dst j step
      lossyFill bb (i + step) n dst (j + step)
    else
      -- U+FFFD is `ef bf bd`, the three bytes `lossyLength` counted for it.
      let _ = byteBlockSetUnsafe j 0xef dst
      let _ = byteBlockSetUnsafe (j + 1) 0xbf dst
      let _ = byteBlockSetUnsafe (j + 2) 0xbd dst
      lossyFill bb (i + (0 - step)) n dst (j + 3)

{- | The string `b` encodes, read as UTF-8, with one U+FFFD replacement
   character substituted for each ill-formed sequence in it.

   `decodeUtf8`'s never-failing form, for a caller that would rather render
   what it was handed than refuse it. The substitution is WHATWG's: one
   replacement character per maximal subpart, so a truncated three-byte
   sequence costs one and three stray continuation bytes cost three. Nothing
   is ever copied through verbatim, so the result is valid UTF-8 whatever `b`
   holds.

   > decodeUtf8Lossy (encodeUtf8 "héllo→")
   "héllo→"
   > decodeUtf8Lossy (fromArrayAssumeByteDomain [|0xff, 0xfe, 104, 105|])
   "��hi"
   > decodeUtf8Lossy (fromArrayAssumeByteDomain [|0xe2, 0x82|])
   "�"
   > toArray (encodeUtf8 (decodeUtf8Lossy (fromArrayAssumeByteDomain [|0xe2, 0x82|])))
   [|239, 191, 189|] -}
export
decodeUtf8Lossy : Bytes -> String
decodeUtf8Lossy (Bytes bb) =
  let n = byteBlockLength bb
  if utf8ValidFrom bb 0 n then
    byteBlockToString bb
  else
    let dst = byteBlockMake (lossyLength bb 0 n 0)
    let _ = lossyFill bb 0 n dst 0
    byteBlockToString dst

-- LAW: every `String` survives the encode/decode round trip unchanged. This
-- is the property `decodeUtf8`'s refusal must not overreach into: a validator
-- that rejects a form the encoder emits would make a byte string no caller
-- can read back.
prop "decodeUtf8 (encodeUtf8 s) == Some s" (s : String) =
  decodeUtf8 (encodeUtf8 s) == Some s

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

{- | Renders as `MutBytes "<hex>"`, in the same lowercase hex shape
   `Debug Bytes` uses -- read from the live buffer, not a `freeze`d copy.

   > debug (mutBytesMake 0)
   "MutBytes \"\""
   > let mb = mutBytesMake 2 in let _ = mutBytesSet 0 255 mb in debug mb
   "MutBytes \"ff00\"" -}
export impl Debug MutBytes where
  debug (MutBytes bb) =
    "MutBytes \"\{debugBytesHex bb 0 (byteBlockLength bb)}\""

-- # Kernel doors

-- The only three exports in this module with a `ByteBlock` in their
-- signature, gathered here rather than beside `fromArray`/`toArray` because
-- crossing to and from the runtime's packed buffer is a different kind of
-- operation from every other door: `adoptByteBlockUnsafe` and
-- `lendByteBlockUnsafe` alias -- the `Bytes` and the block share storage, so
-- a write through the block reaches the `Bytes` and vice versa, which is
-- what the `Unsafe` suffix names -- while `fromByteBlockPrefix` copies, like
-- every other way in or out of `Bytes`, so it carries no suffix. Call these
-- only from a module that already holds a `ByteBlock` of its own --
-- `bytebuilder.mdk`, `net_async.mdk` -- never to route around `Bytes`'s own
-- operations.

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

{- | The byte string holding `bb` itself, with no copy.

   Adopt a block the caller is done with -- one just allocated, or one whose
   owner has finished with it -- or, where the block keeps a writer, one
   whose writer only ever writes where no holder of the byte string reads.

   No domain check runs and none is needed: a `ByteBlock` holds one byte per
   element. The whole block becomes the byte string, so a caller whose live
   bytes are a prefix of a larger buffer wants `fromByteBlockPrefix`, or must
   slice afterwards.

   > toArray (adoptByteBlockUnsafe (byteBlockFromString "hi"))
   [|104, 105|] -}
export
adoptByteBlockUnsafe : ByteBlock -> Bytes
adoptByteBlockUnsafe bb = Bytes bb

{- | The block `b` is built on, with no copy.

   `adoptByteBlockUnsafe`'s counterpart: the way out for a caller that reads
   or blits the bytes and would rather not pay `toArray`'s boxed machine word
   per byte. The block is the byte string's own, so a write to it changes a
   value that hands out no other way to change it. Read it; do not write it.

   > byteBlockLength (lendByteBlockUnsafe (encodeUtf8 "héllo"))
   6 -}
export
lendByteBlockUnsafe : Bytes -> ByteBlock
lendByteBlockUnsafe (Bytes bb) = bb
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Ordering" false) (mem "Debug" false) (mem "Option" false) (mem "Index" false) (mem "Slice" false) (mem "Semigroup" false) (mem "Hashable" false))))
(DUse false (UseGroup ("array") ((mem "findIndex" false) (mem "fromList" false))))
(DUse false (UseGroup ("string") ((mem "toDigit" false))))
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
(DImpl true "Slice" ((TyCon "Bytes")) () ((im "slice" ((PCon "Bytes" (PVar "bb")) (PVar "lo") (PVar "hi")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (EBinOp ">" (EVar "hi") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EBinOp "<" (EBinOp "-" (EVar "hi") (EVar "lo")) (ELit (LInt 0)))) (EApp (EApp (EVar "sliceError") (EVar "lo")) (EBinOp "-" (EVar "hi") (ELit (LInt 1)))) (EBlock (DoLet false false (PVar "dst") (EApp (EVar "byteBlockMake") (EBinOp "-" (EVar "hi") (EVar "lo")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "bb")) (EVar "lo")) (EVar "dst")) (ELit (LInt 0))) (EBinOp "-" (EVar "hi") (EVar "lo")))) (DoExpr (EApp (EVar "Bytes") (EVar "dst"))))))))
(DTypeSig true "sliceClamped" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyCon "Bytes")))))
(DFunDef false "sliceClamped" ((PVar "lo") (PVar "hi") (PCon "Bytes" (PVar "bb"))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "byteBlockLength") (EVar "bb"))) (DoLet false false (PVar "lo'") (EIf (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EApp (EVar "min") (EVar "lo")) (EVar "n")))) (DoLet false false (PVar "hi'") (EIf (EBinOp "<" (EVar "hi") (EVar "lo'")) (EVar "lo'") (EApp (EApp (EVar "min") (EVar "hi")) (EVar "n")))) (DoLet false false (PVar "dst") (EApp (EVar "byteBlockMake") (EBinOp "-" (EVar "hi'") (EVar "lo'")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "bb")) (EVar "lo'")) (EVar "dst")) (ELit (LInt 0))) (EBinOp "-" (EVar "hi'") (EVar "lo'")))) (DoExpr (EApp (EVar "Bytes") (EVar "dst")))))
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
(DTypeSig false "hexDigit" (TyFun (TyCon "Int") (TyCon "Char")))
(DFunDef false "hexDigit" ((PVar "n")) (EMatch (EApp (EVar "toDigit") (EVar "n")) (arm (PCon "Some" (PVar "c")) () (EVar "c")) (arm (PCon "None") () (ELit (LChar "?")))))
(DTypeSig false "debugBytesHex" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "debugBytesHex" ((PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit (LString "")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "b") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "hexDigit") (EApp (EApp (EVar "shiftRight") (EVar "b")) (ELit (LInt 4)))))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "hexDigit") (EApp (EApp (EVar "bitAnd") (EVar "b")) (ELit (LInt 15)))))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "debugBytesHex") (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))) (ELit (LString ""))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "Debug" ((TyCon "Bytes")) () ((im "debug" ((PCon "Bytes" (PVar "bb"))) (EBinOp "++" (EBinOp "++" (ELit (LString "Bytes \"")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "debugBytesHex") (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))))) (ELit (LString "\""))))))
(DTypeSig true "encodeUtf8" (TyFun (TyCon "String") (TyCon "Bytes")))
(DFunDef false "encodeUtf8" ((PVar "s")) (EApp (EVar "Bytes") (EApp (EVar "byteBlockFromString") (EVar "s"))))
(DTypeSig false "utf8Continuation" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "utf8Continuation" ((PVar "bb") (PVar "i")) (EBlock (DoLet false false (PVar "b") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb"))) (DoExpr (EBinOp "&&" (EBinOp ">=" (EVar "b") (ELit (LInt 128))) (EBinOp "<=" (EVar "b") (ELit (LInt 191)))))))
(DTypeSig false "utf8Ill" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "utf8Ill" ((PVar "k")) (EBinOp "-" (ELit (LInt 0)) (EVar "k")))
(DTypeSig false "utf8StepThree" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "utf8StepThree" ((PVar "bb") (PVar "i") (PVar "n") (PVar "b0")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n")) (EApp (EVar "utf8Ill") (ELit (LInt 1))) (EBlock (DoLet false false (PVar "b1") (EApp (EApp (EVar "byteBlockGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "bb"))) (DoLet false false (PVar "b1Ok") (EIf (EBinOp "==" (EVar "b0") (ELit (LInt 224))) (EBinOp "&&" (EBinOp ">=" (EVar "b1") (ELit (LInt 160))) (EBinOp "<=" (EVar "b1") (ELit (LInt 191)))) (EIf (EBinOp "==" (EVar "b0") (ELit (LInt 237))) (EBinOp "&&" (EBinOp ">=" (EVar "b1") (ELit (LInt 128))) (EBinOp "<=" (EVar "b1") (ELit (LInt 159)))) (EBinOp "&&" (EBinOp ">=" (EVar "b1") (ELit (LInt 128))) (EBinOp "<=" (EVar "b1") (ELit (LInt 191))))))) (DoExpr (EIf (EApp (EVar "not") (EVar "b1Ok")) (EApp (EVar "utf8Ill") (ELit (LInt 1))) (EIf (EBinOp "||" (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "utf8Continuation") (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EApp (EVar "utf8Ill") (ELit (LInt 2))) (ELit (LInt 3))))))))
(DTypeSig false "utf8StepFour" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "utf8StepFour" ((PVar "bb") (PVar "i") (PVar "n") (PVar "b0")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n")) (EApp (EVar "utf8Ill") (ELit (LInt 1))) (EBlock (DoLet false false (PVar "b1") (EApp (EApp (EVar "byteBlockGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "bb"))) (DoLet false false (PVar "b1Ok") (EIf (EBinOp "==" (EVar "b0") (ELit (LInt 240))) (EBinOp "&&" (EBinOp ">=" (EVar "b1") (ELit (LInt 144))) (EBinOp "<=" (EVar "b1") (ELit (LInt 191)))) (EIf (EBinOp "==" (EVar "b0") (ELit (LInt 244))) (EBinOp "&&" (EBinOp ">=" (EVar "b1") (ELit (LInt 128))) (EBinOp "<=" (EVar "b1") (ELit (LInt 143)))) (EBinOp "&&" (EBinOp ">=" (EVar "b1") (ELit (LInt 128))) (EBinOp "<=" (EVar "b1") (ELit (LInt 191))))))) (DoExpr (EIf (EApp (EVar "not") (EVar "b1Ok")) (EApp (EVar "utf8Ill") (ELit (LInt 1))) (EIf (EBinOp "||" (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "utf8Continuation") (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EApp (EVar "utf8Ill") (ELit (LInt 2))) (EIf (EBinOp "||" (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 3))) (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "utf8Continuation") (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 3)))))) (EApp (EVar "utf8Ill") (ELit (LInt 3))) (ELit (LInt 4)))))))))
(DTypeSig false "utf8StepAt" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "utf8StepAt" ((PVar "bb") (PVar "i") (PVar "n")) (EBlock (DoLet false false (PVar "b0") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb"))) (DoExpr (EIf (EBinOp "<=" (EVar "b0") (ELit (LInt 127))) (ELit (LInt 1)) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "b0") (ELit (LInt 194))) (EBinOp "<=" (EVar "b0") (ELit (LInt 223)))) (EIf (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n")) (EApp (EApp (EVar "utf8Continuation") (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (ELit (LInt 2)) (EApp (EVar "utf8Ill") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "b0") (ELit (LInt 224))) (EBinOp "<=" (EVar "b0") (ELit (LInt 239)))) (EApp (EApp (EApp (EApp (EVar "utf8StepThree") (EVar "bb")) (EVar "i")) (EVar "n")) (EVar "b0")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "b0") (ELit (LInt 240))) (EBinOp "<=" (EVar "b0") (ELit (LInt 244)))) (EApp (EApp (EApp (EApp (EVar "utf8StepFour") (EVar "bb")) (EVar "i")) (EVar "n")) (EVar "b0")) (EApp (EVar "utf8Ill") (ELit (LInt 1))))))))))
(DTypeSig false "utf8ValidFrom" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "utf8ValidFrom" ((PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "True") (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EVar "utf8StepAt") (EVar "bb")) (EVar "i")) (EVar "n"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EVar "step") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "utf8ValidFrom") (EVar "bb")) (EBinOp "+" (EVar "i") (EVar "step"))) (EVar "n")))))))
(DTypeSig true "decodeUtf8" (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "decodeUtf8" ((PCon "Bytes" (PVar "bb"))) (EIf (EApp (EApp (EApp (EVar "utf8ValidFrom") (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))) (EApp (EVar "Some") (EApp (EVar "byteBlockToString") (EVar "bb"))) (EVar "None")))
(DTypeSig false "lossyLength" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "lossyLength" ((PVar "bb") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EVar "utf8StepAt") (EVar "bb")) (EVar "i")) (EVar "n"))) (DoExpr (EIf (EBinOp ">" (EVar "step") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "lossyLength") (EVar "bb")) (EBinOp "+" (EVar "i") (EVar "step"))) (EVar "n")) (EBinOp "+" (EVar "acc") (EVar "step"))) (EApp (EApp (EApp (EApp (EVar "lossyLength") (EVar "bb")) (EBinOp "+" (EVar "i") (EBinOp "-" (ELit (LInt 0)) (EVar "step")))) (EVar "n")) (EBinOp "+" (EVar "acc") (ELit (LInt 3)))))))))
(DTypeSig false "lossyFill" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyCon "Unit")))))))
(DFunDef false "lossyFill" ((PVar "bb") (PVar "i") (PVar "n") (PVar "dst") (PVar "j")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EVar "utf8StepAt") (EVar "bb")) (EVar "i")) (EVar "n"))) (DoExpr (EIf (EBinOp ">" (EVar "step") (ELit (LInt 0))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "bb")) (EVar "i")) (EVar "dst")) (EVar "j")) (EVar "step"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "lossyFill") (EVar "bb")) (EBinOp "+" (EVar "i") (EVar "step"))) (EVar "n")) (EVar "dst")) (EBinOp "+" (EVar "j") (EVar "step"))))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "byteBlockSetUnsafe") (EVar "j")) (ELit (LInt 239))) (EVar "dst"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "byteBlockSetUnsafe") (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (ELit (LInt 191))) (EVar "dst"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "byteBlockSetUnsafe") (EBinOp "+" (EVar "j") (ELit (LInt 2)))) (ELit (LInt 189))) (EVar "dst"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "lossyFill") (EVar "bb")) (EBinOp "+" (EVar "i") (EBinOp "-" (ELit (LInt 0)) (EVar "step")))) (EVar "n")) (EVar "dst")) (EBinOp "+" (EVar "j") (ELit (LInt 3)))))))))))
(DTypeSig true "decodeUtf8Lossy" (TyFun (TyCon "Bytes") (TyCon "String")))
(DFunDef false "decodeUtf8Lossy" ((PCon "Bytes" (PVar "bb"))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "byteBlockLength") (EVar "bb"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "utf8ValidFrom") (EVar "bb")) (ELit (LInt 0))) (EVar "n")) (EApp (EVar "byteBlockToString") (EVar "bb")) (EBlock (DoLet false false (PVar "dst") (EApp (EVar "byteBlockMake") (EApp (EApp (EApp (EApp (EVar "lossyLength") (EVar "bb")) (ELit (LInt 0))) (EVar "n")) (ELit (LInt 0))))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "lossyFill") (EVar "bb")) (ELit (LInt 0))) (EVar "n")) (EVar "dst")) (ELit (LInt 0)))) (DoExpr (EApp (EVar "byteBlockToString") (EVar "dst"))))))))
(DProp false "decodeUtf8 (encodeUtf8 s) == Some s" ((pp "s" (TyCon "String"))) (EBinOp "==" (EApp (EVar "decodeUtf8") (EApp (EVar "encodeUtf8") (EVar "s"))) (EApp (EVar "Some") (EVar "s"))))
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
(DImpl true "Debug" ((TyCon "MutBytes")) () ((im "debug" ((PCon "MutBytes" (PVar "bb"))) (EBinOp "++" (EBinOp "++" (ELit (LString "MutBytes \"")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "debugBytesHex") (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))))) (ELit (LString "\""))))))
(DTypeSig true "fromByteBlockPrefix" (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyCon "Bytes"))))
(DFunDef false "fromByteBlockPrefix" ((PVar "n") (PVar "bb")) (EIf (EBinOp "||" (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp ">" (EVar "n") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EApp (EVar "panic") (ELit (LString "Bytes.fromByteBlockPrefix: length out of range"))) (EApp (EVar "Bytes") (EApp (EApp (EVar "byteBlockCopyUnsafe") (EVar "n")) (EVar "bb")))))
(DTypeSig true "adoptByteBlockUnsafe" (TyFun (TyCon "ByteBlock") (TyCon "Bytes")))
(DFunDef false "adoptByteBlockUnsafe" ((PVar "bb")) (EApp (EVar "Bytes") (EVar "bb")))
(DTypeSig true "lendByteBlockUnsafe" (TyFun (TyCon "Bytes") (TyCon "ByteBlock")))
(DFunDef false "lendByteBlockUnsafe" ((PCon "Bytes" (PVar "bb"))) (EVar "bb"))
# MARK
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Ordering" false) (mem "Debug" false) (mem "Option" false) (mem "Index" false) (mem "Slice" false) (mem "Semigroup" false) (mem "Hashable" false))))
(DUse false (UseGroup ("array") ((mem "findIndex" false) (mem "fromList" false))))
(DUse false (UseGroup ("string") ((mem "toDigit" false))))
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
(DImpl true "Slice" ((TyCon "Bytes")) () ((im "slice" ((PCon "Bytes" (PVar "bb")) (PVar "lo") (PVar "hi")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (EBinOp ">" (EVar "hi") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EBinOp "<" (EBinOp "-" (EVar "hi") (EVar "lo")) (ELit (LInt 0)))) (EApp (EApp (EVar "sliceError") (EVar "lo")) (EBinOp "-" (EVar "hi") (ELit (LInt 1)))) (EBlock (DoLet false false (PVar "dst") (EApp (EVar "byteBlockMake") (EBinOp "-" (EVar "hi") (EVar "lo")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "bb")) (EVar "lo")) (EVar "dst")) (ELit (LInt 0))) (EBinOp "-" (EVar "hi") (EVar "lo")))) (DoExpr (EApp (EVar "Bytes") (EVar "dst"))))))))
(DTypeSig true "sliceClamped" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyCon "Bytes")))))
(DFunDef false "sliceClamped" ((PVar "lo") (PVar "hi") (PCon "Bytes" (PVar "bb"))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "byteBlockLength") (EVar "bb"))) (DoLet false false (PVar "lo'") (EIf (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EApp (EMethodRef "min") (EVar "lo")) (EVar "n")))) (DoLet false false (PVar "hi'") (EIf (EBinOp "<" (EVar "hi") (EVar "lo'")) (EVar "lo'") (EApp (EApp (EMethodRef "min") (EVar "hi")) (EVar "n")))) (DoLet false false (PVar "dst") (EApp (EVar "byteBlockMake") (EBinOp "-" (EVar "hi'") (EVar "lo'")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "bb")) (EVar "lo'")) (EVar "dst")) (ELit (LInt 0))) (EBinOp "-" (EVar "hi'") (EVar "lo'")))) (DoExpr (EApp (EVar "Bytes") (EVar "dst")))))
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
(DTypeSig false "hexDigit" (TyFun (TyCon "Int") (TyCon "Char")))
(DFunDef false "hexDigit" ((PVar "n")) (EMatch (EApp (EVar "toDigit") (EVar "n")) (arm (PCon "Some" (PVar "c")) () (EVar "c")) (arm (PCon "None") () (ELit (LChar "?")))))
(DTypeSig false "debugBytesHex" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "debugBytesHex" ((PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit (LString "")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "b") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "hexDigit") (EApp (EApp (EVar "shiftRight") (EVar "b")) (ELit (LInt 4)))))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "hexDigit") (EApp (EApp (EVar "bitAnd") (EVar "b")) (ELit (LInt 15)))))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "debugBytesHex") (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))) (ELit (LString ""))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "Debug" ((TyCon "Bytes")) () ((im "debug" ((PCon "Bytes" (PVar "bb"))) (EBinOp "++" (EBinOp "++" (ELit (LString "Bytes \"")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "debugBytesHex") (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))))) (ELit (LString "\""))))))
(DTypeSig true "encodeUtf8" (TyFun (TyCon "String") (TyCon "Bytes")))
(DFunDef false "encodeUtf8" ((PVar "s")) (EApp (EVar "Bytes") (EApp (EVar "byteBlockFromString") (EVar "s"))))
(DTypeSig false "utf8Continuation" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "utf8Continuation" ((PVar "bb") (PVar "i")) (EBlock (DoLet false false (PVar "b") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb"))) (DoExpr (EBinOp "&&" (EBinOp ">=" (EVar "b") (ELit (LInt 128))) (EBinOp "<=" (EVar "b") (ELit (LInt 191)))))))
(DTypeSig false "utf8Ill" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "utf8Ill" ((PVar "k")) (EBinOp "-" (ELit (LInt 0)) (EVar "k")))
(DTypeSig false "utf8StepThree" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "utf8StepThree" ((PVar "bb") (PVar "i") (PVar "n") (PVar "b0")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n")) (EApp (EVar "utf8Ill") (ELit (LInt 1))) (EBlock (DoLet false false (PVar "b1") (EApp (EApp (EVar "byteBlockGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "bb"))) (DoLet false false (PVar "b1Ok") (EIf (EBinOp "==" (EVar "b0") (ELit (LInt 224))) (EBinOp "&&" (EBinOp ">=" (EVar "b1") (ELit (LInt 160))) (EBinOp "<=" (EVar "b1") (ELit (LInt 191)))) (EIf (EBinOp "==" (EVar "b0") (ELit (LInt 237))) (EBinOp "&&" (EBinOp ">=" (EVar "b1") (ELit (LInt 128))) (EBinOp "<=" (EVar "b1") (ELit (LInt 159)))) (EBinOp "&&" (EBinOp ">=" (EVar "b1") (ELit (LInt 128))) (EBinOp "<=" (EVar "b1") (ELit (LInt 191))))))) (DoExpr (EIf (EApp (EVar "not") (EVar "b1Ok")) (EApp (EVar "utf8Ill") (ELit (LInt 1))) (EIf (EBinOp "||" (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "utf8Continuation") (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EApp (EVar "utf8Ill") (ELit (LInt 2))) (ELit (LInt 3))))))))
(DTypeSig false "utf8StepFour" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "utf8StepFour" ((PVar "bb") (PVar "i") (PVar "n") (PVar "b0")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n")) (EApp (EVar "utf8Ill") (ELit (LInt 1))) (EBlock (DoLet false false (PVar "b1") (EApp (EApp (EVar "byteBlockGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "bb"))) (DoLet false false (PVar "b1Ok") (EIf (EBinOp "==" (EVar "b0") (ELit (LInt 240))) (EBinOp "&&" (EBinOp ">=" (EVar "b1") (ELit (LInt 144))) (EBinOp "<=" (EVar "b1") (ELit (LInt 191)))) (EIf (EBinOp "==" (EVar "b0") (ELit (LInt 244))) (EBinOp "&&" (EBinOp ">=" (EVar "b1") (ELit (LInt 128))) (EBinOp "<=" (EVar "b1") (ELit (LInt 143)))) (EBinOp "&&" (EBinOp ">=" (EVar "b1") (ELit (LInt 128))) (EBinOp "<=" (EVar "b1") (ELit (LInt 191))))))) (DoExpr (EIf (EApp (EVar "not") (EVar "b1Ok")) (EApp (EVar "utf8Ill") (ELit (LInt 1))) (EIf (EBinOp "||" (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "utf8Continuation") (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EApp (EVar "utf8Ill") (ELit (LInt 2))) (EIf (EBinOp "||" (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 3))) (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "utf8Continuation") (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 3)))))) (EApp (EVar "utf8Ill") (ELit (LInt 3))) (ELit (LInt 4)))))))))
(DTypeSig false "utf8StepAt" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "utf8StepAt" ((PVar "bb") (PVar "i") (PVar "n")) (EBlock (DoLet false false (PVar "b0") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb"))) (DoExpr (EIf (EBinOp "<=" (EVar "b0") (ELit (LInt 127))) (ELit (LInt 1)) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "b0") (ELit (LInt 194))) (EBinOp "<=" (EVar "b0") (ELit (LInt 223)))) (EIf (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n")) (EApp (EApp (EVar "utf8Continuation") (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (ELit (LInt 2)) (EApp (EVar "utf8Ill") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "b0") (ELit (LInt 224))) (EBinOp "<=" (EVar "b0") (ELit (LInt 239)))) (EApp (EApp (EApp (EApp (EVar "utf8StepThree") (EVar "bb")) (EVar "i")) (EVar "n")) (EVar "b0")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "b0") (ELit (LInt 240))) (EBinOp "<=" (EVar "b0") (ELit (LInt 244)))) (EApp (EApp (EApp (EApp (EVar "utf8StepFour") (EVar "bb")) (EVar "i")) (EVar "n")) (EVar "b0")) (EApp (EVar "utf8Ill") (ELit (LInt 1))))))))))
(DTypeSig false "utf8ValidFrom" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "utf8ValidFrom" ((PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "True") (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EVar "utf8StepAt") (EVar "bb")) (EVar "i")) (EVar "n"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EVar "step") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "utf8ValidFrom") (EVar "bb")) (EBinOp "+" (EVar "i") (EVar "step"))) (EVar "n")))))))
(DTypeSig true "decodeUtf8" (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "decodeUtf8" ((PCon "Bytes" (PVar "bb"))) (EIf (EApp (EApp (EApp (EVar "utf8ValidFrom") (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))) (EApp (EVar "Some") (EApp (EVar "byteBlockToString") (EVar "bb"))) (EVar "None")))
(DTypeSig false "lossyLength" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "lossyLength" ((PVar "bb") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EVar "utf8StepAt") (EVar "bb")) (EVar "i")) (EVar "n"))) (DoExpr (EIf (EBinOp ">" (EVar "step") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "lossyLength") (EVar "bb")) (EBinOp "+" (EVar "i") (EVar "step"))) (EVar "n")) (EBinOp "+" (EVar "acc") (EVar "step"))) (EApp (EApp (EApp (EApp (EVar "lossyLength") (EVar "bb")) (EBinOp "+" (EVar "i") (EBinOp "-" (ELit (LInt 0)) (EVar "step")))) (EVar "n")) (EBinOp "+" (EVar "acc") (ELit (LInt 3)))))))))
(DTypeSig false "lossyFill" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyCon "Unit")))))))
(DFunDef false "lossyFill" ((PVar "bb") (PVar "i") (PVar "n") (PVar "dst") (PVar "j")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EVar "utf8StepAt") (EVar "bb")) (EVar "i")) (EVar "n"))) (DoExpr (EIf (EBinOp ">" (EVar "step") (ELit (LInt 0))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "bb")) (EVar "i")) (EVar "dst")) (EVar "j")) (EVar "step"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "lossyFill") (EVar "bb")) (EBinOp "+" (EVar "i") (EVar "step"))) (EVar "n")) (EVar "dst")) (EBinOp "+" (EVar "j") (EVar "step"))))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "byteBlockSetUnsafe") (EVar "j")) (ELit (LInt 239))) (EVar "dst"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "byteBlockSetUnsafe") (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (ELit (LInt 191))) (EVar "dst"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "byteBlockSetUnsafe") (EBinOp "+" (EVar "j") (ELit (LInt 2)))) (ELit (LInt 189))) (EVar "dst"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "lossyFill") (EVar "bb")) (EBinOp "+" (EVar "i") (EBinOp "-" (ELit (LInt 0)) (EVar "step")))) (EVar "n")) (EVar "dst")) (EBinOp "+" (EVar "j") (ELit (LInt 3)))))))))))
(DTypeSig true "decodeUtf8Lossy" (TyFun (TyCon "Bytes") (TyCon "String")))
(DFunDef false "decodeUtf8Lossy" ((PCon "Bytes" (PVar "bb"))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "byteBlockLength") (EVar "bb"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "utf8ValidFrom") (EVar "bb")) (ELit (LInt 0))) (EVar "n")) (EApp (EVar "byteBlockToString") (EVar "bb")) (EBlock (DoLet false false (PVar "dst") (EApp (EVar "byteBlockMake") (EApp (EApp (EApp (EApp (EVar "lossyLength") (EVar "bb")) (ELit (LInt 0))) (EVar "n")) (ELit (LInt 0))))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "lossyFill") (EVar "bb")) (ELit (LInt 0))) (EVar "n")) (EVar "dst")) (ELit (LInt 0)))) (DoExpr (EApp (EVar "byteBlockToString") (EVar "dst"))))))))
(DProp false "decodeUtf8 (encodeUtf8 s) == Some s" ((pp "s" (TyCon "String"))) (EBinOp "==" (EApp (EVar "decodeUtf8") (EApp (EVar "encodeUtf8") (EVar "s"))) (EApp (EVar "Some") (EVar "s"))))
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
(DImpl true "Debug" ((TyCon "MutBytes")) () ((im "debug" ((PCon "MutBytes" (PVar "bb"))) (EBinOp "++" (EBinOp "++" (ELit (LString "MutBytes \"")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "debugBytesHex") (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))))) (ELit (LString "\""))))))
(DTypeSig true "fromByteBlockPrefix" (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyCon "Bytes"))))
(DFunDef false "fromByteBlockPrefix" ((PVar "n") (PVar "bb")) (EIf (EBinOp "||" (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp ">" (EVar "n") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EApp (EVar "panic") (ELit (LString "Bytes.fromByteBlockPrefix: length out of range"))) (EApp (EVar "Bytes") (EApp (EApp (EVar "byteBlockCopyUnsafe") (EVar "n")) (EVar "bb")))))
(DTypeSig true "adoptByteBlockUnsafe" (TyFun (TyCon "ByteBlock") (TyCon "Bytes")))
(DFunDef false "adoptByteBlockUnsafe" ((PVar "bb")) (EApp (EVar "Bytes") (EVar "bb")))
(DTypeSig true "lendByteBlockUnsafe" (TyFun (TyCon "Bytes") (TyCon "ByteBlock")))
(DFunDef false "lendByteBlockUnsafe" ((PCon "Bytes" (PVar "bb"))) (EVar "bb"))
