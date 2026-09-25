# META
source_lines=986
stages=DESUGAR,MARK
# SOURCE
{- | An immutable string of bytes.

   `Bytes` holds a sequence of bytes that cannot be changed once built. A
   byte is a `U8`, from `0` to `255`: `get`, `b[i]`, `fold` and the other
   element-wise functions hand one out, and `map` and `elemIndex` take one.
   Indices, lengths and offsets are `Int`. Use it for data that is bytes, such as a file's
   contents, a hash digest, or a UTF-8 encoding, and `Array Int` for a
   sequence of numbers that happen to be small. A byte string of `n` bytes
   occupies `n` bytes.

   `fromArray` builds a byte string from an `Array Int` and answers `None`
   when an element is outside `0` to `255`, so no `Bytes` value holds
   anything else. `encodeUtf8` builds one from a `String`. `toArray` and
   `decodeUtf8` go the other way. `mut_bytes.MutBytes` is the mutable
   sibling, for building a byte string a byte at a time.

   `length` is the byte count, `get` reads one byte as an `Option`, and
   `b[i]` is the panicking form. `u8.toInt` widens a byte for arithmetic
   that must not wrap at `255`. `slice`, `take`, `drop`, `indexOf`,
   `startsWith` and the rest follow the shapes of `string` and `list`.
   Byte strings compare lexicographically and can key a `hash_map.HashMap`
   or a `hash_set.HashSet`. `b1 ++ b2` joins two.

   Several names here (`length`, `isEmpty`, `fold`, `map`, `forEach`,
   `any`, `all`) are also prelude names, and others are exported by `list`
   (`take`, `drop`, `splitAt`, `startsWith`, `endsWith`) or by `string` and
   `array` (`concat`). Import the module qualified, as `import bytes as B`,
   in a file that also imports one of those modules.

   Under the interpreter (`medaka run`, `medaka test`), an operation that
   walks the bytes, `==` included, fails with `E-STACK-OVERFLOW` on a byte
   string longer than about 25,000 bytes. Compiled programs have no such
   limit. -}

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
-- This module's `map` shadows `Mappable.map` for this file as well as for an
-- importer, so an example here that would have reached the prelude's method
-- on an `Option` -- `map length (fromArray …)` -- goes through `option`
-- instead.  Reaching for `map` on anything but a `Bytes` inside this file
-- silently picks the one below and fails when its `Bytes` pattern meets the
-- other value.
--
-- The interpreter walk ceiling the module doc states is issue #3269: the
-- evaluator has no tail-call optimisation, so every loop here recurses, and
-- 25,000 is `E-STACK-OVERFLOW`'s threshold.  Removing it is #2594's arc, not
-- this module's.  It is why every doctest subject here stays small.

import core.{
  Ordering(..),
  Ord,
  Debug,
  Option,
  Index,
  Slice,
  Semigroup,
  Monoid,
  Hashable,
}
import array.{findIndex, fromList}
import string.{toDigit}
import u8 as U8

{- | The byte-string type.

   The constructor is private. Build a value with `fromArray`,
   `fromArrayAssumeByteDomain` or `encodeUtf8`, and read it back with
   `toArray`, `decodeUtf8` or `decodeUtf8Lossy`. The functions under Runtime interop
   doors cross to and from the runtime's `ByteBlock` without a conversion.

   > option 0 length (fromArray [|1, 2, 3|])
   3 -}
export newtype Bytes = Bytes ByteBlock

-- The byte at `i` of a block the caller has bounds-checked. A block holds
-- only `0` to `255`, so the conversion keeps every bit.
byteAt : Int -> ByteBlock -> U8
byteAt i bb = u8Truncate (byteBlockGetUnsafe i bb)

-- # Conversion

{- | The byte string holding the elements of `arr`, or `None` when any element
   falls outside `0` to `255`.

   > option [||] toArray (fromArray [|104, 105|])
   [|104, 105|]
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

   Nothing here checks the range. An element outside `0` to `255` is masked
   rather than refused, so `-1` and `511` both store as `255`. Prefer
   `fromArray` unless the elements come from a source that already
   guarantees the range.

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

   This is a plain function, not `Foldable`'s method. Named in an import
   list it shadows the prelude's `length` for the whole importing module.

   > length (encodeUtf8 "héllo")
   6 -}
export
length : Bytes -> Int
length (Bytes bb) = byteBlockLength bb

{- | Whether `b` holds no bytes.

   > isEmpty (fromArrayAssumeByteDomain [||])
   True
   > isEmpty (encodeUtf8 "hi")
   False -}
export
isEmpty : Bytes -> Bool
isEmpty (Bytes bb) = byteBlockLength bb == 0

{- | The byte at index `i`, or `None` when `i` is out of range.

   `b[i]` is the panicking form: on the same out-of-range index, `get`
   answers `None` where `b[i]` raises an index error.

   > get 0 (fromArrayAssumeByteDomain [|7, 8, 9|]) |> option 0 U8.toInt
   7
   > get 3 (fromArrayAssumeByteDomain [|7, 8, 9|])
   None
   > get (-1) (fromArrayAssumeByteDomain [|7, 8, 9|])
   None -}
export
get : Int -> Bytes -> Option U8
get i (Bytes bb) =
  if i < 0 || i >= byteBlockLength bb then None else Some (byteAt i bb)

{- | `b[i]` reads the byte at `i` in `O(1)`.

   Panics with an index error when `i` is out of range; `get` is the
   `Option`-returning form.

   > let b = fromArrayAssumeByteDomain [|7, 8, 9|] in b[1]
   8 -}
export impl Index Bytes Int U8 where
  index (Bytes bb) i =
    if i < 0 || i >= byteBlockLength bb then indexErrorAt i else byteAt i bb

{- | The bytes over `[lo, hi)`, copied into a new byte string. The
   `b.[lo..hi]` and `b.[lo..=hi]` syntax dispatches here.

   The result is a copy, not a view onto `b`. Panics with a slice error when
   the range runs outside the byte string, as `Slice (Array a)` does.

   > toArray (slice (fromArrayAssumeByteDomain [|10, 20, 30, 40, 50|]) 1 3)
   [|20, 30|]
   > toArray (slice (fromArrayAssumeByteDomain [|10, 20|]) 1 1)
   [||] -}
export impl Slice Bytes where
  slice (Bytes bb) lo hi =
    -- `hi < lo` rather than `hi - lo < 0`, as in `Slice (Array a)`: the
    -- difference wraps once `lo` and `hi` are far enough apart, and a range
    -- that slips past the guard reaches `byteBlockBlit` with an out-of-range
    -- offset.
    if lo < 0 || hi > byteBlockLength bb || hi < lo then
      sliceError lo (hi - 1)
    else
      let dst = byteBlockMake (hi - lo)
      let _ = byteBlockBlit bb lo dst 0 (hi - lo)
      Bytes dst

{- | The bytes over `[lo, hi)`, copied into a new byte string, with both
   bounds clamped into the byte string.

   The non-panicking form of `slice`. A range running outside `b` yields a
   shorter byte string, or an empty one, where `b.[lo..hi]` raises a slice
   error.

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

{- | The first `n` bytes of `b`, or all of them when `b` is shorter. Empty
   when `n <= 0`.

   The result is a copy, as `slice`'s is.

   > toArray (take 2 (fromArrayAssumeByteDomain [|10, 20, 30|]))
   [|10, 20|]
   > toArray (take 9 (fromArrayAssumeByteDomain [|10, 20|]))
   [|10, 20|] -}
export
take : Int -> Bytes -> Bytes
take n b = sliceClamped 0 n b

-- > toArray (take (-1) (fromArrayAssumeByteDomain [|10, 20|]))
-- [||]

{- | The bytes of `b` after the first `n`. Empty when `n` is at least `b`'s
   length, and the whole of `b` when `n <= 0`.

   The result is a copy, as `slice`'s is.

   > toArray (drop 2 (fromArrayAssumeByteDomain [|10, 20, 30|]))
   [|30|]
   > toArray (drop 9 (fromArrayAssumeByteDomain [|10, 20|]))
   [||] -}
export
drop : Int -> Bytes -> Bytes
drop n b = sliceClamped n (length b) b

-- > toArray (drop (-1) (fromArrayAssumeByteDomain [|10, 20|]))
-- [|10, 20|]

{- | The first `n` bytes of `b`, and the rest.

   `(take n b, drop n b)`, so both halves are copies and both ends of the
   split clamp into `b`.

   > let (a, b) = splitAt 2 (fromArrayAssumeByteDomain [|10, 20, 30|]) in (toArray a, toArray b)
   ([|10, 20|], [|30|]) -}
export
splitAt : Int -> Bytes -> (Bytes, Bytes)
splitAt n b = (take n b, drop n b)

-- `v` is the needle already widened, so the loop compares machine words.
elemIndexGo : Int -> ByteBlock -> Int -> Int -> Option Int
elemIndexGo v bb i n =
  if i >= n then
    None
  else if byteBlockGetUnsafe i bb == v then
    Some i
  else
    elemIndexGo v bb (i + 1) n

{- | The index of the first byte equal to `v`, or `None` when no byte is.

   The needle is a single byte; `indexOf` searches for a whole byte string.

   > elemIndex 9 (fromArrayAssumeByteDomain [|7, 9, 8, 9|])
   Some 1
   > elemIndex 5 (fromArrayAssumeByteDomain [|7, 9, 8|])
   None -}
export
elemIndex : U8 -> Bytes -> Option Int
elemIndex v (Bytes bb) = elemIndexGo (u8ToInt v) bb 0 (byteBlockLength bb)

{- | The index of the first byte equal to `v` within `[lo, hi)`, or `None`
   when no byte in that range is.

   `lo` and `hi` are clamped into the byte string, as in `sliceClamped`. The
   answer is an index into the whole byte string, not one relative to `lo`.

   > elemIndexWithin 2 5 9 (fromArrayAssumeByteDomain [|7, 9, 8, 9, 9|])
   Some 3
   > elemIndexWithin 0 1 9 (fromArrayAssumeByteDomain [|7, 9, 8, 9, 9|])
   None -}
export
elemIndexWithin : Int -> Int -> U8 -> Bytes -> Option Int
elemIndexWithin lo hi v (Bytes bb) =
  let n = byteBlockLength bb
  let lo' = if lo < 0 then 0 else min lo n
  let hi' = if hi < lo' then lo' else min hi n
  elemIndexGo (u8ToInt v) bb lo' hi'

-- Whether the `n` bytes of `nb` equal `hb`'s `[pos, pos + n)`, read in place.
-- Slicing that window out to compare it with `eq` would allocate an `n`-byte
-- copy at every candidate position, which is the cost the packed
-- representation exists to avoid.
matchesAtGo : ByteBlock -> ByteBlock -> Int -> Int -> Int -> Bool
matchesAtGo nb hb i pos n =
  if i >= n then
    True
  else if byteBlockGetUnsafe i nb == byteBlockGetUnsafe (pos + i) hb then
    matchesAtGo nb hb (i + 1) pos n
  else
    False

indexOfWithinGo : ByteBlock -> Int -> ByteBlock -> Int -> Int -> Option Int
indexOfWithinGo nb nlen hb pos lastPos =
  if pos > lastPos then
    None
  else if matchesAtGo nb hb 0 pos nlen then
    Some pos
  else
    indexOfWithinGo nb nlen hb (pos + 1) lastPos

{- | The index of the first occurrence of `needle` within `[lo, hi)`, or
   `None`.

   `lo` and `hi` are clamped into the byte string, as in `sliceClamped`. The
   answer is an index into the whole byte string, not one relative to `lo`.
   The empty needle occurs at `lo`.

   > indexOfWithin 0 6 (fromArrayAssumeByteDomain [|9, 8|]) (fromArrayAssumeByteDomain [|7, 9, 8, 9, 8, 7|])
   Some 1
   > indexOfWithin 4 6 (fromArrayAssumeByteDomain [|9, 8|]) (fromArrayAssumeByteDomain [|7, 9, 8, 9, 8, 7|])
   None
   > indexOfWithin 2 5 (fromArrayAssumeByteDomain [||]) (fromArrayAssumeByteDomain [|7, 9, 8, 9, 8, 7|])
   Some 2 -}
export
indexOfWithin : Int -> Int -> Bytes -> Bytes -> Option Int
indexOfWithin lo hi (Bytes nb) (Bytes bb) =
  let n = byteBlockLength bb
  let lo' = if lo < 0 then 0 else min lo n
  let hi' = if hi < lo' then lo' else min hi n
  let nlen = byteBlockLength nb
  if nlen == 0 then Some lo' else indexOfWithinGo nb nlen bb lo' (hi' - nlen)

{- | The index of the first occurrence of `needle` in `bytes`, or `None`.

   The needle is a whole byte string; `elemIndex` searches for a single
   byte. The empty needle occurs at index `0`.

   > indexOf (fromArrayAssumeByteDomain [|9, 8|]) (fromArrayAssumeByteDomain [|7, 9, 8, 9|])
   Some 1
   > indexOf (fromArrayAssumeByteDomain [|9, 7|]) (fromArrayAssumeByteDomain [|7, 9, 8, 9|])
   None
   > indexOf (fromArrayAssumeByteDomain [||]) (fromArrayAssumeByteDomain [|7, 9, 8|])
   Some 0 -}
export
indexOf : Bytes -> Bytes -> Option Int
indexOf needle bytes = indexOfWithin 0 (length bytes) needle bytes

{- | The index of the last occurrence of `needle` in `haystack`, or `None`.

   Occurrences may overlap. The empty needle is found at the end of
   `haystack`.

   > lastIndexOf (fromArrayAssumeByteDomain [|9, 8|]) (fromArrayAssumeByteDomain [|9, 8, 7, 9, 8|])
   Some 3
   > lastIndexOf (fromArrayAssumeByteDomain [|9, 7|]) (fromArrayAssumeByteDomain [|9, 8, 7|])
   None -}
export
lastIndexOf : Bytes -> Bytes -> Option Int
lastIndexOf needle haystack
  | length needle == 0 = Some (length haystack)
  | otherwise = lastIndexOfGo needle haystack 0 None

-- Walks forward from each hit, advancing one byte so overlapping matches
-- still count, and keeps the latest. Searching the tail `[from, length)` in
-- place rather than slicing it out keeps the walk allocation-free: the tail
-- copy is `O(length)` per hit, so a needle that hits often costs quadratic
-- bytes.
lastIndexOfGo : Bytes -> Bytes -> Int -> Option Int -> Option Int
lastIndexOfGo needle haystack from acc =
  match indexOfWithin from (length haystack) needle haystack
    None => acc
    Some i => lastIndexOfGo needle haystack (i + 1) (Some i)

{- | Whether `needle` occurs anywhere in `haystack`. The empty needle occurs
   in every byte string.

   > contains (fromArrayAssumeByteDomain [|9, 8|]) (fromArrayAssumeByteDomain [|7, 9, 8|])
   True
   > contains (fromArrayAssumeByteDomain [|9, 7|]) (fromArrayAssumeByteDomain [|7, 9, 8|])
   False -}
export
contains : Bytes -> Bytes -> Bool
contains needle haystack = isSome (indexOf needle haystack)

{- | Whether `b` begins with `prefix`. The empty prefix begins every byte
   string.

   > startsWith (encodeUtf8 "he") (encodeUtf8 "hello")
   True
   > startsWith (encodeUtf8 "lo") (encodeUtf8 "hello")
   False -}
export
startsWith : Bytes -> Bytes -> Bool
startsWith (prefix@(Bytes nb)) (b@(Bytes bb)) =
  let nlen = byteBlockLength nb
  nlen <= byteBlockLength bb && matchesAtGo nb bb 0 0 nlen

-- > startsWith (fromArrayAssumeByteDomain [||]) (encodeUtf8 "hello")
-- True
-- > startsWith (encodeUtf8 "hello!") (encodeUtf8 "hello")
-- False

{- | Whether `b` ends with `suffix`. The empty suffix ends every byte string.

   > endsWith (encodeUtf8 "lo") (encodeUtf8 "hello")
   True
   > endsWith (encodeUtf8 "he") (encodeUtf8 "hello")
   False -}
export
endsWith : Bytes -> Bytes -> Bool
endsWith (suffix@(Bytes nb)) (b@(Bytes bb)) =
  let nlen = byteBlockLength nb
  let hlen = byteBlockLength bb
  nlen <= hlen && matchesAtGo nb bb 0 (hlen - nlen) nlen

-- > endsWith (fromArrayAssumeByteDomain [||]) (encodeUtf8 "hello")
-- True
-- > endsWith (encodeUtf8 "hello!") (encodeUtf8 "hello")
-- False

-- # Iteration

-- Every walk in this section reads the block by index rather than going
-- through `toArray`, which would box a machine word per byte to hand the
-- same values back.

foldGo : (b -> U8 -> <e> b) -> b -> ByteBlock -> Int -> Int -> <e> b
foldGo f acc bb i n =
  if i >= n then acc else foldGo f (f acc (byteAt i bb)) bb (i + 1) n

{- | The result of applying `f` to an accumulator and each byte of `b` in
   turn, starting from `init` and reading left to right.

   Each byte is passed as a `U8`, so an accumulator that sums bytes widens
   each one with `u8.toInt` first. This is a plain function, not
   `Foldable`'s method, and named in an import list it shadows the prelude's
   `fold` for the whole importing module.

   > fold (acc b => acc + U8.toInt b) 0 (fromArrayAssumeByteDomain [|200, 100|])
   300
   > fold (acc b => acc + U8.toInt b) 0 (fromArrayAssumeByteDomain [||])
   0 -}
export
fold : (b -> U8 -> <e> b) -> b -> Bytes -> <e> b
fold f init (Bytes bb) = foldGo f init bb 0 (byteBlockLength bb)

forEachGo : (U8 -> <e> Unit) -> ByteBlock -> Int -> Int -> <e> Unit
forEachGo f bb i n =
  if i >= n then
    ()
  else
    let _ = f (byteAt i bb)
    forEachGo f bb (i + 1) n

{- | Runs `f` on each byte of `b` in order, for its effect.

   > let acc = Ref [] in let _ = forEach (x => acc := U8.toInt x :: !acc) (fromArrayAssumeByteDomain [|7, 8, 9|]) in !acc
   [9, 8, 7] -}
export
forEach : (U8 -> <e> Unit) -> Bytes -> <e> Unit
forEach f (Bytes bb) = forEachGo f bb 0 (byteBlockLength bb)

-- `any` and `all` stop at the byte that settles the answer, where the
-- prelude's `fold`-built versions visit the whole container.  A predicate
-- over a megabyte buffer is the reason this module has them at all.

anyGo : (U8 -> <e> Bool) -> ByteBlock -> Int -> Int -> <e> Bool
anyGo f bb i n =
  if i >= n then
    False
  else if f (byteAt i bb) then
    True
  else
    anyGo f bb (i + 1) n

{- | Whether at least one byte of `b` satisfies `f`. `False` on an empty byte
   string. Stops at the first byte that satisfies `f`.

   > any (x => x > 200) (fromArrayAssumeByteDomain [|1, 250, 3|])
   True
   > any (x => x > 200) (fromArrayAssumeByteDomain [|1, 2, 3|])
   False -}
export
any : (U8 -> <e> Bool) -> Bytes -> <e> Bool
any f (Bytes bb) = anyGo f bb 0 (byteBlockLength bb)

-- > any (x => x > 200) (fromArrayAssumeByteDomain [||])
-- False

allGo : (U8 -> <e> Bool) -> ByteBlock -> Int -> Int -> <e> Bool
allGo f bb i n =
  if i >= n then
    True
  else if f (byteAt i bb) then
    allGo f bb (i + 1) n
  else
    False

{- | Whether every byte of `b` satisfies `f`. `True` on an empty byte string.
   Stops at the first byte that does not satisfy `f`.

   > all (x => x < 200) (fromArrayAssumeByteDomain [|1, 2, 3|])
   True
   > all (x => x < 200) (fromArrayAssumeByteDomain [|1, 250, 3|])
   False -}
export
all : (U8 -> <e> Bool) -> Bytes -> <e> Bool
all f (Bytes bb) = allGo f bb 0 (byteBlockLength bb)

-- > all (x => x < 200) (fromArrayAssumeByteDomain [||])
-- True

mapGo : (U8 -> <e> U8) -> ByteBlock -> ByteBlock -> Int -> Int -> <e> Unit
mapGo f src dst i n =
  if i >= n then
    ()
  else
    let _ = byteBlockSetUnsafe i (u8ToInt (f (byteAt i src))) dst
    mapGo f src dst (i + 1) n

{- | The byte string of the same length holding `f` applied to each byte of
   `b`.

   `f` answers a `U8`, so every result is a byte. Arithmetic on one wraps,
   as `U8`'s does.

   > toArray (map (x => x + 1) (fromArrayAssumeByteDomain [|7, 8, 255|]))
   [|8, 9, 0|] -}
export
map : (U8 -> <e> U8) -> Bytes -> <e> Bytes
map f (Bytes bb) =
  let n = byteBlockLength bb
  let dst = byteBlockMake n
  let _ = mapGo f bb dst 0 n
  Bytes dst

-- # Combining

{- | The bytes of the left operand followed by the bytes of the right, in a
   new byte string.

   `b1 ++ b2` reaches this instance from every position: infix, in an
   operator section, in a body constrained by `Semigroup`, and bound to a
   name first, as `let f = (++)` or `let f = (x y => x ++ y)`. A local
   binding cannot carry the constraint, so a name bound to `++` serves one
   type; used at two, it is rejected, as `let f = append` is.

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

{- | The byte string of no bytes, the identity for `append` and `++`.

   > toArray (empty : Bytes)
   [||]
   > length (append empty (encodeUtf8 "hi"))
   2 -}
export impl Monoid Bytes where
  empty = Bytes (byteBlockMake 0)

concatLength : List Bytes -> Int -> Int
concatLength [] acc = acc
concatLength (b :: rest) acc = concatLength rest (acc + length b)

-- Sums the lengths, then blits each part into one buffer of that size: the
-- `foldRight append empty` spelling would allocate an intermediate byte
-- string per part and copy every earlier part again into each one.
concatFill : List Bytes -> ByteBlock -> Int -> Unit
concatFill [] _ _ = ()
concatFill ((Bytes src) :: rest) dst off =
  let n = byteBlockLength src
  let _ = byteBlockBlit src 0 dst off n
  concatFill rest dst (off + n)

{- | The byte strings joined end to end, in one new byte string.

   > toArray (concat [fromArrayAssumeByteDomain [|1, 2|], fromArrayAssumeByteDomain [|3|]])
   [|1, 2, 3|]
   > decodeUtf8 (concat [encodeUtf8 "hé", encodeUtf8 "llo"])
   Some "héllo" -}
export
concat : List Bytes -> Bytes
concat parts =
  let dst = byteBlockMake (concatLength parts 0)
  let _ = concatFill parts dst 0
  Bytes dst

-- > toArray (concat ([] : List Bytes))
-- [||]

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

{- | Byte strings compare lexicographically, as the arrays of their bytes
   do: byte by byte from the front, with a prefix sorting before what
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

{- | A byte string hashes as the `Array Int` of its bytes does, so `Bytes`
   can key a `hash_map.HashMap` or a `hash_set.HashSet`. Two byte strings
   that are equal under
   `Eq Bytes` hash alike.

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

{- | Renders as `Bytes "<hex>"`: lowercase, two digits per byte, with no
   separator between bytes. The rendering differs from that of the
   equivalent `Array Int`, so a `debug` dump tells the two apart.

   > debug (fromArrayAssumeByteDomain [|7, 8, 9|])
   "Bytes \"070809\""
   > debug (fromArrayAssumeByteDomain [||])
   "Bytes \"\"" -}
export impl Debug Bytes where
  debug (Bytes bb) = "Bytes \"\{debugBytesHex bb 0 (byteBlockLength bb)}\""

-- > debug (encodeUtf8 "hi") /= debug [|104, 105|]
-- True
-- > debug (fromArrayAssumeByteDomain (fromList [0..=31]))
-- "Bytes \"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\""

-- # Text

{- | The UTF-8 encoding of `s`.

   A codepoint outside ASCII encodes to several bytes, so the byte count is
   at least the codepoint count.

   > length (encodeUtf8 "héllo")
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

   Every byte sequence that is not a well-formed UTF-8 encoding of Unicode
   scalar values is refused: a stray continuation byte, a truncated
   sequence, an overlong form, a surrogate, and anything above U+10FFFF.
   `decodeUtf8Lossy` substitutes U+FFFD for each of those instead of
   refusing. `decodeUtf8 (encodeUtf8 s)` is `Some s` for every `s`.

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
   character substituted for each ill-formed sequence.

   The non-failing form of `decodeUtf8`. Substitution follows the WHATWG
   rule of one replacement character per maximal subpart, so a truncated
   three-byte sequence becomes one U+FFFD and three stray continuation
   bytes become three. The result is valid UTF-8 whatever `b` holds.

   > decodeUtf8Lossy (encodeUtf8 "héllo→")
   "héllo→"
   > decodeUtf8Lossy (fromArrayAssumeByteDomain [|0xff, 0xfe, 104, 105|])
   "��hi" -}
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

-- > decodeUtf8Lossy (fromArrayAssumeByteDomain [|0xe2, 0x82|])
-- "�"
-- > toArray (encodeUtf8 (decodeUtf8Lossy (fromArrayAssumeByteDomain [|0xe2, 0x82|])))
-- [|239, 191, 189|]

-- LAW: every `String` survives the encode/decode round trip unchanged. This
-- is the property `decodeUtf8`'s refusal must not overreach into: a validator
-- that rejects a form the encoder emits would make a byte string no caller
-- can read back.
prop "decodeUtf8 (encodeUtf8 s) == Some s" (s : String) =
  decodeUtf8 (encodeUtf8 s) == Some s

-- # Output

{- | Writes the bytes of `b` to standard output, unchanged.

   The bytes need not be valid UTF-8. Nothing decodes or re-encodes them, so
   a sequence that a `String` path would reject or alter is written exactly
   as it is. -}
export
writeStdoutBytes : Bytes -> <Stdout> Unit
writeStdoutBytes (Bytes bb) = byteBlockWriteStdout bb

-- # Runtime interop

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

   No range check is needed: a `ByteBlock` holds one byte per element. The
   result is a copy, so a later write to `bb` does not reach it. Taking a
   length lets a caller freeze the live prefix of a larger buffer.

   Panics when `n` is negative or greater than the block's length.

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

   The byte string and `bb` share storage, so a write to `bb` afterwards
   changes the byte string. Adopt only a block that nothing else will write
   to. The whole block becomes the byte string; for the live prefix of a
   larger buffer use `fromByteBlockPrefix`.

   > toArray (adoptByteBlockUnsafe (byteBlockFromString "hi"))
   [|104, 105|] -}
export
adoptByteBlockUnsafe : ByteBlock -> Bytes
adoptByteBlockUnsafe bb = Bytes bb

{- | The block `b` is built on, with no copy.

   The counterpart of `adoptByteBlockUnsafe`, for a caller that reads or
   blits the bytes without paying for `toArray`'s copy. The block is the
   byte string's own storage, so a write to it changes a value that is meant
   to be immutable. Read it; do not write it.

   > byteBlockLength (lendByteBlockUnsafe (encodeUtf8 "héllo"))
   6 -}
export
lendByteBlockUnsafe : Bytes -> ByteBlock
lendByteBlockUnsafe (Bytes bb) = bb
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Ordering" true) (mem "Ord" false) (mem "Debug" false) (mem "Option" false) (mem "Index" false) (mem "Slice" false) (mem "Semigroup" false) (mem "Monoid" false) (mem "Hashable" false))))
(DUse false (UseGroup ("array") ((mem "findIndex" false) (mem "fromList" false))))
(DUse false (UseGroup ("string") ((mem "toDigit" false))))
(DUse false (UseAlias ("u8") "U8"))
(DNewtype true "Bytes" () "Bytes" (TyCon "ByteBlock") ())
(DTypeSig false "byteAt" (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyCon "U8"))))
(DFunDef false "byteAt" ((PVar "i") (PVar "bb")) (EApp (EVar "u8Truncate") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb"))))
(DTypeSig true "fromArray" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Bytes"))))
(DFunDef false "fromArray" ((PVar "arr")) (EMatch (EApp (EApp (EVar "findIndex") (ELam ((PVar "b")) (EBinOp "||" (EBinOp "<" (EVar "b") (ELit (LInt 0))) (EBinOp ">" (EVar "b") (ELit (LInt 255)))))) (EVar "arr")) (arm (PCon "Some" PWild) () (EVar "None")) (arm (PCon "None") () (EApp (EVar "Some") (EApp (EVar "Bytes") (EApp (EVar "byteBlockFromIntArray") (EVar "arr")))))))
(DTypeSig true "fromArrayAssumeByteDomain" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Bytes")))
(DFunDef false "fromArrayAssumeByteDomain" ((PVar "arr")) (EApp (EVar "Bytes") (EApp (EVar "byteBlockFromIntArray") (EVar "arr"))))
(DTypeSig true "toArray" (TyFun (TyCon "Bytes") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "toArray" ((PCon "Bytes" (PVar "bb"))) (EApp (EVar "byteBlockToIntArray") (EVar "bb")))
(DTypeSig true "length" (TyFun (TyCon "Bytes") (TyCon "Int")))
(DFunDef false "length" ((PCon "Bytes" (PVar "bb"))) (EApp (EVar "byteBlockLength") (EVar "bb")))
(DTypeSig true "isEmpty" (TyFun (TyCon "Bytes") (TyCon "Bool")))
(DFunDef false "isEmpty" ((PCon "Bytes" (PVar "bb"))) (EBinOp "==" (EApp (EVar "byteBlockLength") (EVar "bb")) (ELit (LInt 0))))
(DTypeSig true "get" (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "U8")))))
(DFunDef false "get" ((PVar "i") (PCon "Bytes" (PVar "bb"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "byteAt") (EVar "i")) (EVar "bb")))))
(DImpl true "Index" ((TyCon "Bytes") (TyCon "Int") (TyCon "U8")) () ((im "index" ((PCon "Bytes" (PVar "bb")) (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EApp (EVar "indexErrorAt") (EVar "i")) (EApp (EApp (EVar "byteAt") (EVar "i")) (EVar "bb"))))))
(DImpl true "Slice" ((TyCon "Bytes")) () ((im "slice" ((PCon "Bytes" (PVar "bb")) (PVar "lo") (PVar "hi")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (EBinOp ">" (EVar "hi") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EBinOp "<" (EVar "hi") (EVar "lo"))) (EApp (EApp (EVar "sliceError") (EVar "lo")) (EBinOp "-" (EVar "hi") (ELit (LInt 1)))) (EBlock (DoLet false false (PVar "dst") (EApp (EVar "byteBlockMake") (EBinOp "-" (EVar "hi") (EVar "lo")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "bb")) (EVar "lo")) (EVar "dst")) (ELit (LInt 0))) (EBinOp "-" (EVar "hi") (EVar "lo")))) (DoExpr (EApp (EVar "Bytes") (EVar "dst"))))))))
(DTypeSig true "sliceClamped" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyCon "Bytes")))))
(DFunDef false "sliceClamped" ((PVar "lo") (PVar "hi") (PCon "Bytes" (PVar "bb"))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "byteBlockLength") (EVar "bb"))) (DoLet false false (PVar "lo'") (EIf (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EApp (EVar "min") (EVar "lo")) (EVar "n")))) (DoLet false false (PVar "hi'") (EIf (EBinOp "<" (EVar "hi") (EVar "lo'")) (EVar "lo'") (EApp (EApp (EVar "min") (EVar "hi")) (EVar "n")))) (DoLet false false (PVar "dst") (EApp (EVar "byteBlockMake") (EBinOp "-" (EVar "hi'") (EVar "lo'")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "bb")) (EVar "lo'")) (EVar "dst")) (ELit (LInt 0))) (EBinOp "-" (EVar "hi'") (EVar "lo'")))) (DoExpr (EApp (EVar "Bytes") (EVar "dst")))))
(DTypeSig true "take" (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyCon "Bytes"))))
(DFunDef false "take" ((PVar "n") (PVar "b")) (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 0))) (EVar "n")) (EVar "b")))
(DTypeSig true "drop" (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyCon "Bytes"))))
(DFunDef false "drop" ((PVar "n") (PVar "b")) (EApp (EApp (EApp (EVar "sliceClamped") (EVar "n")) (EApp (EVar "length") (EVar "b"))) (EVar "b")))
(DTypeSig true "splitAt" (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyTuple (TyCon "Bytes") (TyCon "Bytes")))))
(DFunDef false "splitAt" ((PVar "n") (PVar "b")) (ETuple (EApp (EApp (EVar "take") (EVar "n")) (EVar "b")) (EApp (EApp (EVar "drop") (EVar "n")) (EVar "b"))))
(DTypeSig false "elemIndexGo" (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "elemIndexGo" ((PVar "v") (PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb")) (EVar "v")) (EApp (EVar "Some") (EVar "i")) (EApp (EApp (EApp (EApp (EVar "elemIndexGo") (EVar "v")) (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig true "elemIndex" (TyFun (TyCon "U8") (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "elemIndex" ((PVar "v") (PCon "Bytes" (PVar "bb"))) (EApp (EApp (EApp (EApp (EVar "elemIndexGo") (EApp (EVar "u8ToInt") (EVar "v"))) (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))))
(DTypeSig true "elemIndexWithin" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "U8") (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "elemIndexWithin" ((PVar "lo") (PVar "hi") (PVar "v") (PCon "Bytes" (PVar "bb"))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "byteBlockLength") (EVar "bb"))) (DoLet false false (PVar "lo'") (EIf (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EApp (EVar "min") (EVar "lo")) (EVar "n")))) (DoLet false false (PVar "hi'") (EIf (EBinOp "<" (EVar "hi") (EVar "lo'")) (EVar "lo'") (EApp (EApp (EVar "min") (EVar "hi")) (EVar "n")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "elemIndexGo") (EApp (EVar "u8ToInt") (EVar "v"))) (EVar "bb")) (EVar "lo'")) (EVar "hi'")))))
(DTypeSig false "matchesAtGo" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "matchesAtGo" ((PVar "nb") (PVar "hb") (PVar "i") (PVar "pos") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "True") (EIf (EBinOp "==" (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "nb")) (EApp (EApp (EVar "byteBlockGetUnsafe") (EBinOp "+" (EVar "pos") (EVar "i"))) (EVar "hb"))) (EApp (EApp (EApp (EApp (EApp (EVar "matchesAtGo") (EVar "nb")) (EVar "hb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "pos")) (EVar "n")) (EVar "False"))))
(DTypeSig false "indexOfWithinGo" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "indexOfWithinGo" ((PVar "nb") (PVar "nlen") (PVar "hb") (PVar "pos") (PVar "lastPos")) (EIf (EBinOp ">" (EVar "pos") (EVar "lastPos")) (EVar "None") (EIf (EApp (EApp (EApp (EApp (EApp (EVar "matchesAtGo") (EVar "nb")) (EVar "hb")) (ELit (LInt 0))) (EVar "pos")) (EVar "nlen")) (EApp (EVar "Some") (EVar "pos")) (EApp (EApp (EApp (EApp (EApp (EVar "indexOfWithinGo") (EVar "nb")) (EVar "nlen")) (EVar "hb")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "lastPos")))))
(DTypeSig true "indexOfWithin" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "indexOfWithin" ((PVar "lo") (PVar "hi") (PCon "Bytes" (PVar "nb")) (PCon "Bytes" (PVar "bb"))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "byteBlockLength") (EVar "bb"))) (DoLet false false (PVar "lo'") (EIf (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EApp (EVar "min") (EVar "lo")) (EVar "n")))) (DoLet false false (PVar "hi'") (EIf (EBinOp "<" (EVar "hi") (EVar "lo'")) (EVar "lo'") (EApp (EApp (EVar "min") (EVar "hi")) (EVar "n")))) (DoLet false false (PVar "nlen") (EApp (EVar "byteBlockLength") (EVar "nb"))) (DoExpr (EIf (EBinOp "==" (EVar "nlen") (ELit (LInt 0))) (EApp (EVar "Some") (EVar "lo'")) (EApp (EApp (EApp (EApp (EApp (EVar "indexOfWithinGo") (EVar "nb")) (EVar "nlen")) (EVar "bb")) (EVar "lo'")) (EBinOp "-" (EVar "hi'") (EVar "nlen")))))))
(DTypeSig true "indexOf" (TyFun (TyCon "Bytes") (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "indexOf" ((PVar "needle") (PVar "bytes")) (EApp (EApp (EApp (EApp (EVar "indexOfWithin") (ELit (LInt 0))) (EApp (EVar "length") (EVar "bytes"))) (EVar "needle")) (EVar "bytes")))
(DTypeSig true "lastIndexOf" (TyFun (TyCon "Bytes") (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "lastIndexOf" ((PVar "needle") (PVar "haystack")) (EIf (EBinOp "==" (EApp (EVar "length") (EVar "needle")) (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EVar "length") (EVar "haystack"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "lastIndexOfGo") (EVar "needle")) (EVar "haystack")) (ELit (LInt 0))) (EVar "None")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "lastIndexOfGo" (TyFun (TyCon "Bytes") (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "lastIndexOfGo" ((PVar "needle") (PVar "haystack") (PVar "from") (PVar "acc")) (EMatch (EApp (EApp (EApp (EApp (EVar "indexOfWithin") (EVar "from")) (EApp (EVar "length") (EVar "haystack"))) (EVar "needle")) (EVar "haystack")) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EApp (EVar "lastIndexOfGo") (EVar "needle")) (EVar "haystack")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "Some") (EVar "i"))))))
(DTypeSig true "contains" (TyFun (TyCon "Bytes") (TyFun (TyCon "Bytes") (TyCon "Bool"))))
(DFunDef false "contains" ((PVar "needle") (PVar "haystack")) (EApp (EVar "isSome") (EApp (EApp (EVar "indexOf") (EVar "needle")) (EVar "haystack"))))
(DTypeSig true "startsWith" (TyFun (TyCon "Bytes") (TyFun (TyCon "Bytes") (TyCon "Bool"))))
(DFunDef false "startsWith" ((PAs "prefix" (PCon "Bytes" (PVar "nb"))) (PAs "b" (PCon "Bytes" (PVar "bb")))) (EBlock (DoLet false false (PVar "nlen") (EApp (EVar "byteBlockLength") (EVar "nb"))) (DoExpr (EBinOp "&&" (EBinOp "<=" (EVar "nlen") (EApp (EVar "byteBlockLength") (EVar "bb"))) (EApp (EApp (EApp (EApp (EApp (EVar "matchesAtGo") (EVar "nb")) (EVar "bb")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "nlen"))))))
(DTypeSig true "endsWith" (TyFun (TyCon "Bytes") (TyFun (TyCon "Bytes") (TyCon "Bool"))))
(DFunDef false "endsWith" ((PAs "suffix" (PCon "Bytes" (PVar "nb"))) (PAs "b" (PCon "Bytes" (PVar "bb")))) (EBlock (DoLet false false (PVar "nlen") (EApp (EVar "byteBlockLength") (EVar "nb"))) (DoLet false false (PVar "hlen") (EApp (EVar "byteBlockLength") (EVar "bb"))) (DoExpr (EBinOp "&&" (EBinOp "<=" (EVar "nlen") (EVar "hlen")) (EApp (EApp (EApp (EApp (EApp (EVar "matchesAtGo") (EVar "nb")) (EVar "bb")) (ELit (LInt 0))) (EBinOp "-" (EVar "hlen") (EVar "nlen"))) (EVar "nlen"))))))
(DTypeSig false "foldGo" (TyFun (TyFun (TyVar "b") (TyFun (TyCon "U8") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyVar "b"))))))))
(DFunDef false "foldGo" ((PVar "f") (PVar "acc") (PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EApp (EApp (EApp (EApp (EApp (EVar "foldGo") (EVar "f")) (EApp (EApp (EVar "f") (EVar "acc")) (EApp (EApp (EVar "byteAt") (EVar "i")) (EVar "bb")))) (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))))
(DTypeSig true "fold" (TyFun (TyFun (TyVar "b") (TyFun (TyCon "U8") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyCon "Bytes") (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "fold" ((PVar "f") (PVar "init") (PCon "Bytes" (PVar "bb"))) (EApp (EApp (EApp (EApp (EApp (EVar "foldGo") (EVar "f")) (EVar "init")) (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))))
(DTypeSig false "forEachGo" (TyFun (TyFun (TyCon "U8") (TyEffect () (Some "e") (TyCon "Unit"))) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit")))))))
(DFunDef false "forEachGo" ((PVar "f") (PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "f") (EApp (EApp (EVar "byteAt") (EVar "i")) (EVar "bb")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "forEachGo") (EVar "f")) (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))))))
(DTypeSig true "forEach" (TyFun (TyFun (TyCon "U8") (TyEffect () (Some "e") (TyCon "Unit"))) (TyFun (TyCon "Bytes") (TyEffect () (Some "e") (TyCon "Unit")))))
(DFunDef false "forEach" ((PVar "f") (PCon "Bytes" (PVar "bb"))) (EApp (EApp (EApp (EApp (EVar "forEachGo") (EVar "f")) (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))))
(DTypeSig false "anyGo" (TyFun (TyFun (TyCon "U8") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Bool")))))))
(DFunDef false "anyGo" ((PVar "f") (PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "False") (EIf (EApp (EVar "f") (EApp (EApp (EVar "byteAt") (EVar "i")) (EVar "bb"))) (EVar "True") (EApp (EApp (EApp (EApp (EVar "anyGo") (EVar "f")) (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig true "any" (TyFun (TyFun (TyCon "U8") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyCon "Bytes") (TyEffect () (Some "e") (TyCon "Bool")))))
(DFunDef false "any" ((PVar "f") (PCon "Bytes" (PVar "bb"))) (EApp (EApp (EApp (EApp (EVar "anyGo") (EVar "f")) (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))))
(DTypeSig false "allGo" (TyFun (TyFun (TyCon "U8") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Bool")))))))
(DFunDef false "allGo" ((PVar "f") (PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "True") (EIf (EApp (EVar "f") (EApp (EApp (EVar "byteAt") (EVar "i")) (EVar "bb"))) (EApp (EApp (EApp (EApp (EVar "allGo") (EVar "f")) (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "False"))))
(DTypeSig true "all" (TyFun (TyFun (TyCon "U8") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyCon "Bytes") (TyEffect () (Some "e") (TyCon "Bool")))))
(DFunDef false "all" ((PVar "f") (PCon "Bytes" (PVar "bb"))) (EApp (EApp (EApp (EApp (EVar "allGo") (EVar "f")) (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))))
(DTypeSig false "mapGo" (TyFun (TyFun (TyCon "U8") (TyEffect () (Some "e") (TyCon "U8"))) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit"))))))))
(DFunDef false "mapGo" ((PVar "f") (PVar "src") (PVar "dst") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "byteBlockSetUnsafe") (EVar "i")) (EApp (EVar "u8ToInt") (EApp (EVar "f") (EApp (EApp (EVar "byteAt") (EVar "i")) (EVar "src"))))) (EVar "dst"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "mapGo") (EVar "f")) (EVar "src")) (EVar "dst")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))))))
(DTypeSig true "map" (TyFun (TyFun (TyCon "U8") (TyEffect () (Some "e") (TyCon "U8"))) (TyFun (TyCon "Bytes") (TyEffect () (Some "e") (TyCon "Bytes")))))
(DFunDef false "map" ((PVar "f") (PCon "Bytes" (PVar "bb"))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "byteBlockLength") (EVar "bb"))) (DoLet false false (PVar "dst") (EApp (EVar "byteBlockMake") (EVar "n"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "mapGo") (EVar "f")) (EVar "bb")) (EVar "dst")) (ELit (LInt 0))) (EVar "n"))) (DoExpr (EApp (EVar "Bytes") (EVar "dst")))))
(DImpl true "Semigroup" ((TyCon "Bytes")) () ((im "append" ((PCon "Bytes" (PVar "a")) (PCon "Bytes" (PVar "b"))) (EBlock (DoLet false false (PVar "na") (EApp (EVar "byteBlockLength") (EVar "a"))) (DoLet false false (PVar "nb") (EApp (EVar "byteBlockLength") (EVar "b"))) (DoLet false false (PVar "dst") (EApp (EVar "byteBlockMake") (EBinOp "+" (EVar "na") (EVar "nb")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "a")) (ELit (LInt 0))) (EVar "dst")) (ELit (LInt 0))) (EVar "na"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "b")) (ELit (LInt 0))) (EVar "dst")) (EVar "na")) (EVar "nb"))) (DoExpr (EApp (EVar "Bytes") (EVar "dst")))))))
(DImpl true "Monoid" ((TyCon "Bytes")) () ((im "empty" () (EApp (EVar "Bytes") (EApp (EVar "byteBlockMake") (ELit (LInt 0)))))))
(DTypeSig false "concatLength" (TyFun (TyApp (TyCon "List") (TyCon "Bytes")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "concatLength" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "concatLength" ((PCons (PVar "b") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "concatLength") (EVar "rest")) (EBinOp "+" (EVar "acc") (EApp (EVar "length") (EVar "b")))))
(DTypeSig false "concatFill" (TyFun (TyApp (TyCon "List") (TyCon "Bytes")) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyCon "Unit")))))
(DFunDef false "concatFill" ((PList) PWild PWild) (ELit LUnit))
(DFunDef false "concatFill" ((PCons (PCon "Bytes" (PVar "src")) (PVar "rest")) (PVar "dst") (PVar "off")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "byteBlockLength") (EVar "src"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "src")) (ELit (LInt 0))) (EVar "dst")) (EVar "off")) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EVar "concatFill") (EVar "rest")) (EVar "dst")) (EBinOp "+" (EVar "off") (EVar "n"))))))
(DTypeSig true "concat" (TyFun (TyApp (TyCon "List") (TyCon "Bytes")) (TyCon "Bytes")))
(DFunDef false "concat" ((PVar "parts")) (EBlock (DoLet false false (PVar "dst") (EApp (EVar "byteBlockMake") (EApp (EApp (EVar "concatLength") (EVar "parts")) (ELit (LInt 0))))) (DoLet false false PWild (EApp (EApp (EApp (EVar "concatFill") (EVar "parts")) (EVar "dst")) (ELit (LInt 0)))) (DoExpr (EApp (EVar "Bytes") (EVar "dst")))))
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
(DTypeSig true "fromByteBlockPrefix" (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyCon "Bytes"))))
(DFunDef false "fromByteBlockPrefix" ((PVar "n") (PVar "bb")) (EIf (EBinOp "||" (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp ">" (EVar "n") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EApp (EVar "panic") (ELit (LString "Bytes.fromByteBlockPrefix: length out of range"))) (EApp (EVar "Bytes") (EApp (EApp (EVar "byteBlockCopyUnsafe") (EVar "n")) (EVar "bb")))))
(DTypeSig true "adoptByteBlockUnsafe" (TyFun (TyCon "ByteBlock") (TyCon "Bytes")))
(DFunDef false "adoptByteBlockUnsafe" ((PVar "bb")) (EApp (EVar "Bytes") (EVar "bb")))
(DTypeSig true "lendByteBlockUnsafe" (TyFun (TyCon "Bytes") (TyCon "ByteBlock")))
(DFunDef false "lendByteBlockUnsafe" ((PCon "Bytes" (PVar "bb"))) (EVar "bb"))
# MARK
(DUse false (UseGroup ("core") ((mem "Ordering" true) (mem "Ord" false) (mem "Debug" false) (mem "Option" false) (mem "Index" false) (mem "Slice" false) (mem "Semigroup" false) (mem "Monoid" false) (mem "Hashable" false))))
(DUse false (UseGroup ("array") ((mem "findIndex" false) (mem "fromList" false))))
(DUse false (UseGroup ("string") ((mem "toDigit" false))))
(DUse false (UseAlias ("u8") "U8"))
(DNewtype true "Bytes" () "Bytes" (TyCon "ByteBlock") ())
(DTypeSig false "byteAt" (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyCon "U8"))))
(DFunDef false "byteAt" ((PVar "i") (PVar "bb")) (EApp (EVar "u8Truncate") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb"))))
(DTypeSig true "fromArray" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Bytes"))))
(DFunDef false "fromArray" ((PVar "arr")) (EMatch (EApp (EApp (EVar "findIndex") (ELam ((PVar "b")) (EBinOp "||" (EBinOp "<" (EVar "b") (ELit (LInt 0))) (EBinOp ">" (EVar "b") (ELit (LInt 255)))))) (EVar "arr")) (arm (PCon "Some" PWild) () (EVar "None")) (arm (PCon "None") () (EApp (EVar "Some") (EApp (EVar "Bytes") (EApp (EVar "byteBlockFromIntArray") (EVar "arr")))))))
(DTypeSig true "fromArrayAssumeByteDomain" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Bytes")))
(DFunDef false "fromArrayAssumeByteDomain" ((PVar "arr")) (EApp (EVar "Bytes") (EApp (EVar "byteBlockFromIntArray") (EVar "arr"))))
(DTypeSig true "toArray" (TyFun (TyCon "Bytes") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "toArray" ((PCon "Bytes" (PVar "bb"))) (EApp (EVar "byteBlockToIntArray") (EVar "bb")))
(DTypeSig true "length#shadow" (TyFun (TyCon "Bytes") (TyCon "Int")))
(DFunDef false "length#shadow" ((PCon "Bytes" (PVar "bb"))) (EApp (EVar "byteBlockLength") (EVar "bb")))
(DTypeSig true "isEmpty#shadow" (TyFun (TyCon "Bytes") (TyCon "Bool")))
(DFunDef false "isEmpty#shadow" ((PCon "Bytes" (PVar "bb"))) (EBinOp "==" (EApp (EVar "byteBlockLength") (EVar "bb")) (ELit (LInt 0))))
(DTypeSig true "get" (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "U8")))))
(DFunDef false "get" ((PVar "i") (PCon "Bytes" (PVar "bb"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "byteAt") (EVar "i")) (EVar "bb")))))
(DImpl true "Index" ((TyCon "Bytes") (TyCon "Int") (TyCon "U8")) () ((im "index" ((PCon "Bytes" (PVar "bb")) (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EApp (EVar "indexErrorAt") (EVar "i")) (EApp (EApp (EVar "byteAt") (EVar "i")) (EVar "bb"))))))
(DImpl true "Slice" ((TyCon "Bytes")) () ((im "slice" ((PCon "Bytes" (PVar "bb")) (PVar "lo") (PVar "hi")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (EBinOp ">" (EVar "hi") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EBinOp "<" (EVar "hi") (EVar "lo"))) (EApp (EApp (EVar "sliceError") (EVar "lo")) (EBinOp "-" (EVar "hi") (ELit (LInt 1)))) (EBlock (DoLet false false (PVar "dst") (EApp (EVar "byteBlockMake") (EBinOp "-" (EVar "hi") (EVar "lo")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "bb")) (EVar "lo")) (EVar "dst")) (ELit (LInt 0))) (EBinOp "-" (EVar "hi") (EVar "lo")))) (DoExpr (EApp (EVar "Bytes") (EVar "dst"))))))))
(DTypeSig true "sliceClamped" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyCon "Bytes")))))
(DFunDef false "sliceClamped" ((PVar "lo") (PVar "hi") (PCon "Bytes" (PVar "bb"))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "byteBlockLength") (EVar "bb"))) (DoLet false false (PVar "lo'") (EIf (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EApp (EMethodRef "min") (EVar "lo")) (EVar "n")))) (DoLet false false (PVar "hi'") (EIf (EBinOp "<" (EVar "hi") (EVar "lo'")) (EVar "lo'") (EApp (EApp (EMethodRef "min") (EVar "hi")) (EVar "n")))) (DoLet false false (PVar "dst") (EApp (EVar "byteBlockMake") (EBinOp "-" (EVar "hi'") (EVar "lo'")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "bb")) (EVar "lo'")) (EVar "dst")) (ELit (LInt 0))) (EBinOp "-" (EVar "hi'") (EVar "lo'")))) (DoExpr (EApp (EVar "Bytes") (EVar "dst")))))
(DTypeSig true "take" (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyCon "Bytes"))))
(DFunDef false "take" ((PVar "n") (PVar "b")) (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 0))) (EVar "n")) (EVar "b")))
(DTypeSig true "drop" (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyCon "Bytes"))))
(DFunDef false "drop" ((PVar "n") (PVar "b")) (EApp (EApp (EApp (EVar "sliceClamped") (EVar "n")) (EApp (EVar "length#shadow") (EVar "b"))) (EVar "b")))
(DTypeSig true "splitAt" (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyTuple (TyCon "Bytes") (TyCon "Bytes")))))
(DFunDef false "splitAt" ((PVar "n") (PVar "b")) (ETuple (EApp (EApp (EVar "take") (EVar "n")) (EVar "b")) (EApp (EApp (EVar "drop") (EVar "n")) (EVar "b"))))
(DTypeSig false "elemIndexGo" (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "elemIndexGo" ((PVar "v") (PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb")) (EVar "v")) (EApp (EVar "Some") (EVar "i")) (EApp (EApp (EApp (EApp (EVar "elemIndexGo") (EVar "v")) (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig true "elemIndex" (TyFun (TyCon "U8") (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "elemIndex" ((PVar "v") (PCon "Bytes" (PVar "bb"))) (EApp (EApp (EApp (EApp (EVar "elemIndexGo") (EApp (EVar "u8ToInt") (EVar "v"))) (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))))
(DTypeSig true "elemIndexWithin" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "U8") (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "elemIndexWithin" ((PVar "lo") (PVar "hi") (PVar "v") (PCon "Bytes" (PVar "bb"))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "byteBlockLength") (EVar "bb"))) (DoLet false false (PVar "lo'") (EIf (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EApp (EMethodRef "min") (EVar "lo")) (EVar "n")))) (DoLet false false (PVar "hi'") (EIf (EBinOp "<" (EVar "hi") (EVar "lo'")) (EVar "lo'") (EApp (EApp (EMethodRef "min") (EVar "hi")) (EVar "n")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "elemIndexGo") (EApp (EVar "u8ToInt") (EVar "v"))) (EVar "bb")) (EVar "lo'")) (EVar "hi'")))))
(DTypeSig false "matchesAtGo" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "matchesAtGo" ((PVar "nb") (PVar "hb") (PVar "i") (PVar "pos") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "True") (EIf (EBinOp "==" (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "nb")) (EApp (EApp (EVar "byteBlockGetUnsafe") (EBinOp "+" (EVar "pos") (EVar "i"))) (EVar "hb"))) (EApp (EApp (EApp (EApp (EApp (EVar "matchesAtGo") (EVar "nb")) (EVar "hb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "pos")) (EVar "n")) (EVar "False"))))
(DTypeSig false "indexOfWithinGo" (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "indexOfWithinGo" ((PVar "nb") (PVar "nlen") (PVar "hb") (PVar "pos") (PVar "lastPos")) (EIf (EBinOp ">" (EVar "pos") (EVar "lastPos")) (EVar "None") (EIf (EApp (EApp (EApp (EApp (EApp (EVar "matchesAtGo") (EVar "nb")) (EVar "hb")) (ELit (LInt 0))) (EVar "pos")) (EVar "nlen")) (EApp (EVar "Some") (EVar "pos")) (EApp (EApp (EApp (EApp (EApp (EVar "indexOfWithinGo") (EVar "nb")) (EVar "nlen")) (EVar "hb")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "lastPos")))))
(DTypeSig true "indexOfWithin" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "indexOfWithin" ((PVar "lo") (PVar "hi") (PCon "Bytes" (PVar "nb")) (PCon "Bytes" (PVar "bb"))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "byteBlockLength") (EVar "bb"))) (DoLet false false (PVar "lo'") (EIf (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EApp (EMethodRef "min") (EVar "lo")) (EVar "n")))) (DoLet false false (PVar "hi'") (EIf (EBinOp "<" (EVar "hi") (EVar "lo'")) (EVar "lo'") (EApp (EApp (EMethodRef "min") (EVar "hi")) (EVar "n")))) (DoLet false false (PVar "nlen") (EApp (EVar "byteBlockLength") (EVar "nb"))) (DoExpr (EIf (EBinOp "==" (EVar "nlen") (ELit (LInt 0))) (EApp (EVar "Some") (EVar "lo'")) (EApp (EApp (EApp (EApp (EApp (EVar "indexOfWithinGo") (EVar "nb")) (EVar "nlen")) (EVar "bb")) (EVar "lo'")) (EBinOp "-" (EVar "hi'") (EVar "nlen")))))))
(DTypeSig true "indexOf" (TyFun (TyCon "Bytes") (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "indexOf" ((PVar "needle") (PVar "bytes")) (EApp (EApp (EApp (EApp (EVar "indexOfWithin") (ELit (LInt 0))) (EApp (EVar "length#shadow") (EVar "bytes"))) (EVar "needle")) (EVar "bytes")))
(DTypeSig true "lastIndexOf" (TyFun (TyCon "Bytes") (TyFun (TyCon "Bytes") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "lastIndexOf" ((PVar "needle") (PVar "haystack")) (EIf (EBinOp "==" (EApp (EVar "length#shadow") (EVar "needle")) (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EVar "length#shadow") (EVar "haystack"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "lastIndexOfGo") (EVar "needle")) (EVar "haystack")) (ELit (LInt 0))) (EVar "None")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "lastIndexOfGo" (TyFun (TyCon "Bytes") (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "lastIndexOfGo" ((PVar "needle") (PVar "haystack") (PVar "from") (PVar "acc")) (EMatch (EApp (EApp (EApp (EApp (EVar "indexOfWithin") (EVar "from")) (EApp (EVar "length#shadow") (EVar "haystack"))) (EVar "needle")) (EVar "haystack")) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EApp (EVar "lastIndexOfGo") (EVar "needle")) (EVar "haystack")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "Some") (EVar "i"))))))
(DTypeSig true "contains" (TyFun (TyCon "Bytes") (TyFun (TyCon "Bytes") (TyCon "Bool"))))
(DFunDef false "contains" ((PVar "needle") (PVar "haystack")) (EApp (EVar "isSome") (EApp (EApp (EVar "indexOf") (EVar "needle")) (EVar "haystack"))))
(DTypeSig true "startsWith" (TyFun (TyCon "Bytes") (TyFun (TyCon "Bytes") (TyCon "Bool"))))
(DFunDef false "startsWith" ((PAs "prefix" (PCon "Bytes" (PVar "nb"))) (PAs "b" (PCon "Bytes" (PVar "bb")))) (EBlock (DoLet false false (PVar "nlen") (EApp (EVar "byteBlockLength") (EVar "nb"))) (DoExpr (EBinOp "&&" (EBinOp "<=" (EVar "nlen") (EApp (EVar "byteBlockLength") (EVar "bb"))) (EApp (EApp (EApp (EApp (EApp (EVar "matchesAtGo") (EVar "nb")) (EVar "bb")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "nlen"))))))
(DTypeSig true "endsWith" (TyFun (TyCon "Bytes") (TyFun (TyCon "Bytes") (TyCon "Bool"))))
(DFunDef false "endsWith" ((PAs "suffix" (PCon "Bytes" (PVar "nb"))) (PAs "b" (PCon "Bytes" (PVar "bb")))) (EBlock (DoLet false false (PVar "nlen") (EApp (EVar "byteBlockLength") (EVar "nb"))) (DoLet false false (PVar "hlen") (EApp (EVar "byteBlockLength") (EVar "bb"))) (DoExpr (EBinOp "&&" (EBinOp "<=" (EVar "nlen") (EVar "hlen")) (EApp (EApp (EApp (EApp (EApp (EVar "matchesAtGo") (EVar "nb")) (EVar "bb")) (ELit (LInt 0))) (EBinOp "-" (EVar "hlen") (EVar "nlen"))) (EVar "nlen"))))))
(DTypeSig false "foldGo" (TyFun (TyFun (TyVar "b") (TyFun (TyCon "U8") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyVar "b"))))))))
(DFunDef false "foldGo" ((PVar "f") (PVar "acc") (PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EApp (EApp (EApp (EApp (EApp (EVar "foldGo") (EVar "f")) (EApp (EApp (EVar "f") (EVar "acc")) (EApp (EApp (EVar "byteAt") (EVar "i")) (EVar "bb")))) (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))))
(DTypeSig true "fold#shadow" (TyFun (TyFun (TyVar "b") (TyFun (TyCon "U8") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyCon "Bytes") (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "fold#shadow" ((PVar "f") (PVar "init") (PCon "Bytes" (PVar "bb"))) (EApp (EApp (EApp (EApp (EApp (EVar "foldGo") (EVar "f")) (EVar "init")) (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))))
(DTypeSig false "forEachGo" (TyFun (TyFun (TyCon "U8") (TyEffect () (Some "e") (TyCon "Unit"))) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit")))))))
(DFunDef false "forEachGo" ((PVar "f") (PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "f") (EApp (EApp (EVar "byteAt") (EVar "i")) (EVar "bb")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "forEachGo") (EVar "f")) (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))))))
(DTypeSig true "forEach" (TyFun (TyFun (TyCon "U8") (TyEffect () (Some "e") (TyCon "Unit"))) (TyFun (TyCon "Bytes") (TyEffect () (Some "e") (TyCon "Unit")))))
(DFunDef false "forEach" ((PVar "f") (PCon "Bytes" (PVar "bb"))) (EApp (EApp (EApp (EApp (EVar "forEachGo") (EVar "f")) (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))))
(DTypeSig false "anyGo" (TyFun (TyFun (TyCon "U8") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Bool")))))))
(DFunDef false "anyGo" ((PVar "f") (PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "False") (EIf (EApp (EVar "f") (EApp (EApp (EVar "byteAt") (EVar "i")) (EVar "bb"))) (EVar "True") (EApp (EApp (EApp (EApp (EVar "anyGo") (EVar "f")) (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig true "any" (TyFun (TyFun (TyCon "U8") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyCon "Bytes") (TyEffect () (Some "e") (TyCon "Bool")))))
(DFunDef false "any" ((PVar "f") (PCon "Bytes" (PVar "bb"))) (EApp (EApp (EApp (EApp (EVar "anyGo") (EVar "f")) (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))))
(DTypeSig false "allGo" (TyFun (TyFun (TyCon "U8") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Bool")))))))
(DFunDef false "allGo" ((PVar "f") (PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "True") (EIf (EApp (EVar "f") (EApp (EApp (EVar "byteAt") (EVar "i")) (EVar "bb"))) (EApp (EApp (EApp (EApp (EVar "allGo") (EVar "f")) (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "False"))))
(DTypeSig true "all" (TyFun (TyFun (TyCon "U8") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyCon "Bytes") (TyEffect () (Some "e") (TyCon "Bool")))))
(DFunDef false "all" ((PVar "f") (PCon "Bytes" (PVar "bb"))) (EApp (EApp (EApp (EApp (EVar "allGo") (EVar "f")) (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb"))))
(DTypeSig false "mapGo" (TyFun (TyFun (TyCon "U8") (TyEffect () (Some "e") (TyCon "U8"))) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit"))))))))
(DFunDef false "mapGo" ((PVar "f") (PVar "src") (PVar "dst") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "byteBlockSetUnsafe") (EVar "i")) (EApp (EVar "u8ToInt") (EApp (EVar "f") (EApp (EApp (EVar "byteAt") (EVar "i")) (EVar "src"))))) (EVar "dst"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "mapGo") (EVar "f")) (EVar "src")) (EVar "dst")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))))))
(DTypeSig true "map#shadow" (TyFun (TyFun (TyCon "U8") (TyEffect () (Some "e") (TyCon "U8"))) (TyFun (TyCon "Bytes") (TyEffect () (Some "e") (TyCon "Bytes")))))
(DFunDef false "map#shadow" ((PVar "f") (PCon "Bytes" (PVar "bb"))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "byteBlockLength") (EVar "bb"))) (DoLet false false (PVar "dst") (EApp (EVar "byteBlockMake") (EVar "n"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "mapGo") (EVar "f")) (EVar "bb")) (EVar "dst")) (ELit (LInt 0))) (EVar "n"))) (DoExpr (EApp (EVar "Bytes") (EVar "dst")))))
(DImpl true "Semigroup" ((TyCon "Bytes")) () ((im "append" ((PCon "Bytes" (PVar "a")) (PCon "Bytes" (PVar "b"))) (EBlock (DoLet false false (PVar "na") (EApp (EVar "byteBlockLength") (EVar "a"))) (DoLet false false (PVar "nb") (EApp (EVar "byteBlockLength") (EVar "b"))) (DoLet false false (PVar "dst") (EApp (EVar "byteBlockMake") (EBinOp "+" (EVar "na") (EVar "nb")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "a")) (ELit (LInt 0))) (EVar "dst")) (ELit (LInt 0))) (EVar "na"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "b")) (ELit (LInt 0))) (EVar "dst")) (EVar "na")) (EVar "nb"))) (DoExpr (EApp (EVar "Bytes") (EVar "dst")))))))
(DImpl true "Monoid" ((TyCon "Bytes")) () ((im "empty" () (EApp (EVar "Bytes") (EApp (EVar "byteBlockMake") (ELit (LInt 0)))))))
(DTypeSig false "concatLength" (TyFun (TyApp (TyCon "List") (TyCon "Bytes")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "concatLength" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "concatLength" ((PCons (PVar "b") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "concatLength") (EVar "rest")) (EBinOp "+" (EVar "acc") (EApp (EVar "length#shadow") (EVar "b")))))
(DTypeSig false "concatFill" (TyFun (TyApp (TyCon "List") (TyCon "Bytes")) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyCon "Unit")))))
(DFunDef false "concatFill" ((PList) PWild PWild) (ELit LUnit))
(DFunDef false "concatFill" ((PCons (PCon "Bytes" (PVar "src")) (PVar "rest")) (PVar "dst") (PVar "off")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "byteBlockLength") (EVar "src"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "src")) (ELit (LInt 0))) (EVar "dst")) (EVar "off")) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EVar "concatFill") (EVar "rest")) (EVar "dst")) (EBinOp "+" (EVar "off") (EVar "n"))))))
(DTypeSig true "concat" (TyFun (TyApp (TyCon "List") (TyCon "Bytes")) (TyCon "Bytes")))
(DFunDef false "concat" ((PVar "parts")) (EBlock (DoLet false false (PVar "dst") (EApp (EVar "byteBlockMake") (EApp (EApp (EVar "concatLength") (EVar "parts")) (ELit (LInt 0))))) (DoLet false false PWild (EApp (EApp (EApp (EVar "concatFill") (EVar "parts")) (EVar "dst")) (ELit (LInt 0)))) (DoExpr (EApp (EVar "Bytes") (EVar "dst")))))
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
(DTypeSig true "fromByteBlockPrefix" (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyCon "Bytes"))))
(DFunDef false "fromByteBlockPrefix" ((PVar "n") (PVar "bb")) (EIf (EBinOp "||" (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp ">" (EVar "n") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EApp (EVar "panic") (ELit (LString "Bytes.fromByteBlockPrefix: length out of range"))) (EApp (EVar "Bytes") (EApp (EApp (EVar "byteBlockCopyUnsafe") (EVar "n")) (EVar "bb")))))
(DTypeSig true "adoptByteBlockUnsafe" (TyFun (TyCon "ByteBlock") (TyCon "Bytes")))
(DFunDef false "adoptByteBlockUnsafe" ((PVar "bb")) (EApp (EVar "Bytes") (EVar "bb")))
(DTypeSig true "lendByteBlockUnsafe" (TyFun (TyCon "Bytes") (TyCon "ByteBlock")))
(DFunDef false "lendByteBlockUnsafe" ((PCon "Bytes" (PVar "bb"))) (EVar "bb"))
