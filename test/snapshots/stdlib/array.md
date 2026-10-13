# META
source_lines=889
stages=DESUGAR,MARK
# SOURCE
{- | Operations on `Array a`.

   An array is a fixed-size sequence with `O(1)` indexing, written
   `[|1, 2, 3|]`. The functions here return new arrays, except those whose
   names say they work in place (`setInPlace`, `swap`, `fill`, `blit`,
   `sortInPlace`), which change the array they are given and return `Unit`.
   For an array that grows, see `vector`.

   `length`, `isEmpty`, `toList`, `map`, `filter`, `fold`, `elem`, `sum`,
   `maximum`, and the other `Foldable` and `Mappable` operations work on
   arrays through the instances in this module and the prelude. `arr[i]`
   panics on an out-of-range index; `get` is the `Option`-returning form. -}

-- Two design tensions shape this module:
--
--   1. Performance vs. functional feel.  The public API is a pure facade
--      where it can be (`map`, `filter`, `sort`, etc. return fresh arrays)
--      and explicitly mutates in place where that's the whole point
--      (`setInPlace`, `swap`, `sortInPlace`), untracked, no effect in the
--      signature.
--
--   2. Opaque builtin vs. typeclass member.  `Array a` cannot be pattern-
--      matched like `List a`, so the impls below dispatch through the
--      `array*` primitives declared in stdlib/runtime.mdk.  We implement
--      `Mappable`, `Foldable`, `Eq`, `Debug`, `Semigroup`, `Monoid`, and
--      deliberately skip `Applicative` / `Thenable`, because the natural
--      definitions would encode cartesian-style allocation that's a
--      performance trap on bulk data.
--
-- Most operations here are one or two lines of Medaka built on
-- `arrayMakeWith` + `arrayGetUnsafe`, which compile to a tight loop in the
-- host runtime.

import core.{
  Ordering(..),
  Ord,
  Debug,
  Display,
  Foldable,
  Mappable,
  Filterable,
  Semigroup,
  Monoid,
  Option,
}

-- # Construction

-- The empty array is `Monoid.empty` (see `impl Monoid (Array a)` below); use
-- the `[||]` literal directly inside this module.

{- | An array holding one element.

   > toList (singleton 5)
   [5] -}
export
singleton : a -> Array a
singleton x = [|x|]

{- | An array of `n` copies of `x`.

   > toList (make 3 0)
   [0, 0, 0] -}
export
make : Int -> a -> Array a
make n x = arrayMake n x

{- | An array of length `n` whose element at each index `i` is `f i`.

   Empty when `n <= 0`.

   > toList (makeWith 3 (i => i * 2))
   [0, 2, 4] -}
export
makeWith : Int -> (Int -> <e> a) -> <e> Array a
makeWith n f = if n <= 0 then [||] else arrayMakeWith n f

-- > length (makeWith 0 (i => i))
-- 0

{- | An array holding the elements of a list, in order.

   > fromList [1, 2, 3]
   [|1, 2, 3|] -}
export
fromList : List a -> Array a
fromList xs = arrayFromList xs

{- | The integers from `lo` up to, but not including, `hi`.

   Empty when `hi <= lo`.

   > toList (range 0 4)
   [0, 1, 2, 3] -}
export
range : Int -> Int -> Array Int
range lo hi = arrayMakeWith (if hi > lo then hi - lo else 0) (lo + _)

{- | A new array with the same elements.

   Use it to keep the original before an in-place operation.

   > copy [|1, 2|]
   [|1, 2|] -}
export
copy : Array a -> Array a
copy arr = arrayCopy arr

-- # Reading

-- `length`, `isEmpty`, `toList` are provided by `impl Foldable Array` below;
-- they're not re-exported as standalone names because that would collide
-- with the polymorphic Foldable methods of the same name.

{- | The element at index `i`, or `None` when `i` is out of range.

   `arr[i]` is the panicking form.

   > get 0 (fromList [1, 2, 3])
   Some 1
   > get 5 (fromList [1, 2, 3])
   None -}
export
get : Int -> Array a -> Option a
get i arr =
  if i < 0 || i >= arrayLength arr then None else Some (arrayGetUnsafe i arr)

{- | The first element, or `None` when the array is empty.

   > first (fromList [1, 2, 3])
   Some 1 -}
export
first : Array a -> Option a
first arr = get 0 arr

{- | The last element, or `None` when the array is empty.

   > last (fromList [1, 2, 3])
   Some 3 -}
export
last : Array a -> Option a
last arr = get (arrayLength arr - 1) arr

-- # Transformation

-- `map` is provided by `impl Mappable Array` below; not re-exported as a
-- standalone name to avoid colliding with `Mappable.map`.

{- | A new array with the elements in reverse order.

   > toList (reverse (fromList [1, 2, 3]))
   [3, 2, 1] -}
export
reverse : Array a -> Array a
reverse arr =
  let n = arrayLength arr
  arrayMakeWith n (i => arrayGetUnsafe (n - 1 - i) arr)

{- | A new array of the elements at indices `[lo, hi)`.

   Indices are clamped to the array, so an out-of-range slice is shorter
   rather than a panic. `arr.[lo..hi]` is the panicking form.

   > toList (sliceClamped 1 3 (fromList [1, 2, 3, 4, 5]))
   [2, 3] -}
export
sliceClamped : Int -> Int -> Array a -> Array a
sliceClamped lo hi arr =
  let n = arrayLength arr
  let lo' = if lo < 0 then 0 else min lo n
  let hi' = if hi < lo' then lo' else min hi n
  let m = hi' - lo'
  if m <= 0 then
    [||]
  else
    let out = arrayMake m (arrayGetUnsafe lo' arr)
    let _ = arrayBlit arr lo' out 0 m
    out

{- | A new array of the first `n` elements, or of the whole array when it
   is shorter.

   > toList (take 2 (fromList [1, 2, 3, 4]))
   [1, 2] -}
export
take : Int -> Array a -> Array a
take n arr = sliceClamped 0 n arr

{- | A new array of everything after the first `n` elements.

   > toList (drop 2 (fromList [1, 2, 3, 4]))
   [3, 4] -}
export
drop : Int -> Array a -> Array a
drop n arr = sliceClamped n (arrayLength arr) arr

-- `append` comes from `impl Semigroup (Array a)` (also the `++` operator).

-- Two passes: sum the inner lengths, then bulk-copy each inner array into the
-- result with one `arrayBlit` per inner.
{- | The inner arrays joined into one.

   Costs `O(n)` in the total number of elements.

   > toList (concat (fromList [fromList [1, 2], fromList [3]]))
   [1, 2, 3] -}
export
concat : Array (Array a) -> Array a
concat arrs =
  let outer = arrayLength arrs
  let total = concatTotal arrs 0 0 outer
  if total <= 0 then
    [||]
  else
    let out = arrayMake total (concatLookup arrs 0 0 outer)
    concatBlitAll arrs out 0 0 outer

concatBlitAll : Array (Array a) -> Array a -> Int -> Int -> Int -> Array a
concatBlitAll arrs out k dstOff outer =
  if k >= outer then
    out
  else
    let inner = arrayGetUnsafe k arrs
    let len = arrayLength inner
    if len <= 0 then
      concatBlitAll arrs out (k + 1) dstOff outer
    else
      let _ = arrayBlit inner 0 out dstOff len
      concatBlitAll arrs out (k + 1) (dstOff + len) outer

concatTotal : Array (Array a) -> Int -> Int -> Int -> Int
concatTotal arrs i acc outer =
  if i >= outer then
    acc
  else
    concatTotal arrs (i + 1) (acc + arrayLength (arrayGetUnsafe i arrs)) outer

{- Element `target` of the concatenation, found by walking the outer array
   and subtracting inner lengths.  O(outer).  `concat` calls this exactly ONCE,
   for `target = 0`, to obtain the allocation seed. -}
concatLookup : Array (Array a) -> Int -> Int -> Int -> a
concatLookup arrs target k outer =
  let inner = arrayGetUnsafe k arrs
  let len = arrayLength inner
  if target < len then
    arrayGetUnsafe target inner
  else
    concatLookup arrs (target - len) (k + 1) outer

{- | The elements of two arrays paired up by position.

   The result is as long as the shorter input.

   > toList (zip (fromList [1, 2, 3]) (fromList ["a", "b"]))
   [(1, "a"), (2, "b")] -}
export
zip : Array a -> Array b -> Array (a, b)
zip a b =
  let n = min (arrayLength a) (arrayLength b)
  arrayMakeWith n (i => (arrayGetUnsafe i a, arrayGetUnsafe i b))

{- | The elements of two arrays combined by position with `f`.

   The result is as long as the shorter input.

   > toList (zipWith (x y => x + y) (fromList [1, 2]) (fromList [10, 20]))
   [11, 22] -}
export
zipWith : (a -> b -> <e> c) -> Array a -> Array b -> <e> Array c
zipWith f a b =
  let n = min (arrayLength a) (arrayLength b)
  arrayMakeWith n (i => f (arrayGetUnsafe i a) (arrayGetUnsafe i b))

{- | An array of pairs separated into two arrays. The inverse of `zip`.

   > let (xs, ys) = unzip (fromList [(1, 2), (3, 4)]) in (toList xs, toList ys)
   ([1, 3], [2, 4]) -}
export
unzip : Array (a, b) -> (Array a, Array b)
unzip arr =
  let n = arrayLength arr
  (
    arrayMakeWith n (i => fst (arrayGetUnsafe i arr)),
    arrayMakeWith n (i => snd (arrayGetUnsafe i arr)),
  )

{- | `filter` and `filterMap` return a new array of the elements that
   survive.

   > toList (filter isEven (fromList [1, 2, 3, 4]))
   [2, 4] -}
export impl Filterable Array where
  filter p arr =
    let n = arrayLength arr
    if n == 0 then
      [||]
    else
      let buf = arrayMake n (arrayGetUnsafe 0 arr)
      filterFinish buf (filterGo p arr buf 0 0 n) n

  filterMap f arr = filterMapFrom f arr 0 (arrayLength arr)

-- Survivors are written into a scratch buffer of the input's length, and the
-- exact-size result is copied out once at the end.
filterGo : (a -> <e> Bool) -> Array a -> Array a -> Int -> Int -> Int -> <e> Int
filterGo p arr buf i k n =
  if i >= n then
    k
  else
    let x = arrayGetUnsafe i arr
    if p x then
      let _ = arraySetUnsafe k x buf
      filterGo p arr buf (i + 1) (k + 1) n
    else
      filterGo p arr buf (i + 1) k n

-- The buffer's first `k` elements are the result. `buf` is non-empty.
filterFinish : Array a -> Int -> Int -> Array a
filterFinish buf k n =
  if k <= 0 then
    [||]
  else if k == n then
    buf
  else
    let out = arrayMake k (arrayGetUnsafe 0 buf)
    let _ = arrayBlit buf 0 out 0 k
    out

-- The buffer is created from the first survivor, which supplies the element
-- type's seed value; every slot is then overwritten or discarded by the
-- final copy.
filterMapFrom : (a -> <e> Option b) -> Array a -> Int -> Int -> <e> Array b
filterMapFrom f arr i n =
  if i >= n then
    [||]
  else match f (arrayGetUnsafe i arr)
    None => filterMapFrom f arr (i + 1) n
    Some y =>
      let buf = arrayMake n y
      filterFinish buf (filterMapGo f arr buf (i + 1) n 1) n

filterMapGo : (a -> <e> Option b) ->
  Array a ->
  Array b ->
  Int ->
  Int ->
  Int ->
  <e> Int
filterMapGo f arr buf i n k =
  if i >= n then
    k
  else match f (arrayGetUnsafe i arr)
    Some y =>
      let _ = arraySetUnsafe k y buf
      filterMapGo f arr buf (i + 1) n (k + 1)
    None => filterMapGo f arr buf (i + 1) n k

-- # Mutation

{- | Replaces the element at index `i` with `x`.

   Panics when `i` is out of range.

   > let arr = fromList [1, 2, 3] in let _ = setInPlace 1 9 arr in toList arr
   [1, 9, 3] -}
export
setInPlace : Int -> a -> Array a -> Unit
setInPlace i x arr =
  if i < 0 || i >= arrayLength arr then
    indexErrorAt i
  else
    arraySetUnsafe i x arr

{- | Exchanges the elements at indices `i` and `j`.

   Both indices must be in range.

   > let arr = fromList [1, 2, 3] in let _ = swap 0 2 arr in toList arr
   [3, 2, 1] -}
export
swap : Int -> Int -> Array a -> Unit
swap i j arr =
  let xi = arrayGetUnsafe i arr
  let xj = arrayGetUnsafe j arr
  arraySetUnsafe i xj arr
  arraySetUnsafe j xi arr

{- | Replaces every element with `x`.

   > let arr = fromList [1, 2, 3] in let _ = fill 0 arr in toList arr
   [0, 0, 0] -}
export
fill : a -> Array a -> Unit
fill x arr = arrayFill x arr

{- | Copies `len` elements from `src`, starting at `srcOff`, into `dst`,
   starting at `dstOff`.

   Panics when any argument is negative or the copy would run past either
   array's end.

   > let dst = make 4 0 in let _ = blit (fromList [1, 2]) 0 dst 1 2 in toList dst
   [0, 1, 2, 0] -}
export
blit : Array a -> Int -> Array a -> Int -> Int -> Unit
blit src srcOff dst dstOff len =
  -- Each bound is `len > length - off` rather than `off + len > length`: the
  -- sum overflows for an `off` near `maxBound`. The negative-argument arms
  -- come first so the subtraction cannot itself overflow. `mut_bytes.blit` guards the same way.
  if len < 0 then
    panic "Array.blit: negative length"
  else if srcOff < 0 then
    panic "Array.blit: negative srcOff"
  else if dstOff < 0 then
    panic "Array.blit: negative dstOff"
  else if len > arrayLength src - srcOff then
    panic "Array.blit: source out of bounds"
  else if len > arrayLength dst - dstOff then
    panic "Array.blit: destination out of bounds"
  else
    arrayBlit src srcOff dst dstOff len

-- # Sorting

{- | Sorts the array in place by `cmp`.

   The sort is stable.

   > let arr = fromList [3, 1, 2] in let _ = sortInPlaceBy compare arr in toList arr
   [1, 2, 3] -}
export
sortInPlaceBy : (a -> a -> <e> Ordering) -> Array a -> <e> Unit
sortInPlaceBy cmp arr =
  let sorted = sortBy cmp arr
  arrayBlit sorted 0 arr 0 (arrayLength arr)

{- | Sorts the array in place in ascending order.

   The sort is stable.

   > let arr = fromList [3, 1, 2] in let _ = sortInPlace arr in toList arr
   [1, 2, 3] -}
export
sortInPlace : Ord a => Array a -> Unit
sortInPlace arr = sortInPlaceBy compare arr

{- | A new array of the elements sorted by `cmp`.

   The sort is stable: elements that compare equal keep their original
   order. It costs `O(n log n)`.

   > toList (sortBy (x y => compare y x) (fromList [3, 1, 2]))
   [3, 2, 1] -}
export
sortBy : (a -> a -> <e> Ordering) -> Array a -> <e> Array a
sortBy cmp arr =
  let n = arrayLength arr
  if n <= 1 then
    arrayCopy arr
  else
    let src = arrayCopy arr
    let _ = sortRuns cmp src n 8 0
    mergePasses cmp src (arrayMake n (arrayGetUnsafe 0 arr)) n 8

-- > toList (sortBy compare (fromList [3, 1, 4, 1, 5]))
-- [1, 1, 3, 4, 5]

{- | A new array of the elements in ascending order.

   The sort is stable.

   > toList (sort (fromList [3, 1, 4, 1, 5]))
   [1, 1, 3, 4, 5] -}
export
sort : Ord a => Array a -> Array a
sort arr = sortBy compare arr

{- | A new array of the elements in ascending order of `key`.

   `key` is computed once per element, so it may be expensive. The sort is
   stable.

   > toList (sortOn (x => 0 - x) (fromList [1, 3, 2]))
   [3, 2, 1] -}
export
sortOn : Ord b => (a -> <e> b) -> Array a -> <e> Array a
sortOn key arr =
  let n = arrayLength arr
  let keys = arrayMakeWith n (i => key (arrayGetUnsafe i arr))
  let order =
    sortBy
      (i j => compare (arrayGetUnsafe i keys) (arrayGetUnsafe j keys))
      (arrayMakeWith n (i => i))
  arrayMakeWith n (i => arrayGetUnsafe (arrayGetUnsafe i order) arr)

-- ── Merge helpers ─────────────────────────────────────────────────────

-- Insertion-sorts each run of `w` elements, from index `lo` on, in place.
-- Stable: an element moves left only past strictly greater elements.
sortRuns : (a -> a -> <e> Ordering) -> Array a -> Int -> Int -> Int -> <e> Unit
sortRuns cmp a n w lo =
  if lo >= n then
    ()
  else
    let hi = min (lo + w) n
    let _ = insertionRun cmp a lo hi (lo + 1)
    sortRuns cmp a n w hi

insertionRun : (a -> a -> <e> Ordering) ->
  Array a ->
  Int ->
  Int ->
  Int ->
  <e> Unit
insertionRun cmp a lo hi i =
  if i >= hi then
    ()
  else
    let x = arrayGetUnsafe i a
    let _ = insertionShift cmp a lo i x
    insertionRun cmp a lo hi (i + 1)

insertionShift : (a -> a -> <e> Ordering) ->
  Array a ->
  Int ->
  Int ->
  a ->
  <e> Unit
insertionShift cmp a lo j x =
  if j <= lo then
    arraySetUnsafe j x a
  else if isNotGt cmp (arrayGetUnsafe (j - 1) a) x then
    arraySetUnsafe j x a
  else
    let _ = arraySetUnsafe j (arrayGetUnsafe (j - 1) a) a
    insertionShift cmp a lo (j - 1) x

-- Bottom-up merge sort over two equal-length buffers, `src` and `dst`. Each
-- pass merges adjacent runs of `width` from `src` into `dst`, then the roles
-- swap and `width` doubles; the buffer that holds the sorted run is returned.
-- Stable: on ties the left run's element is taken first.
mergePasses : (a -> a -> <e> Ordering) ->
  Array a ->
  Array a ->
  Int ->
  Int ->
  <e> Array a
mergePasses cmp src dst n width =
  if width >= n then
    src
  else
    let _ = mergeRuns cmp src dst n width 0
    mergePasses cmp dst src n (width * 2)

mergeRuns : (a -> a -> <e> Ordering) ->
  Array a ->
  Array a ->
  Int ->
  Int ->
  Int ->
  <e> Unit
mergeRuns cmp src dst n width lo =
  if lo >= n then
    ()
  else
    let mid = min (lo + width) n
    let hi = min (lo + width + width) n
    let _ = mergePair cmp src dst lo mid hi
    mergeRuns cmp src dst n width hi

-- Merges the adjacent runs `src[lo, mid)` and `src[mid, hi)` into `dst`. When
-- the left run's last element is not greater than the right run's first, the
-- runs are already in order and the merge is a plain copy.
mergePair : (a -> a -> <e> Ordering) ->
  Array a ->
  Array a ->
  Int ->
  Int ->
  Int ->
  <e> Unit
mergePair cmp src dst lo mid hi =
  if mid >= hi
    || isNotGt cmp (arrayGetUnsafe (mid - 1) src) (arrayGetUnsafe mid src) then
    arrayBlit src lo dst lo (hi - lo)
  else
    mergeRun cmp src dst lo mid mid hi lo

isNotGt : (a -> a -> <e> Ordering) -> a -> a -> <e> Bool
isNotGt cmp x y = match cmp x y
  Gt => False
  _ => True

-- Merges `src[i, iEnd)` and `src[j, jEnd)` into `dst` from index `k` on.
mergeRun : (a -> a -> <e> Ordering) ->
  Array a ->
  Array a ->
  Int ->
  Int ->
  Int ->
  Int ->
  Int ->
  <e> Unit
mergeRun cmp src dst i iEnd j jEnd k =
  if i >= iEnd then
    copyRun src dst j jEnd k
  else if j >= jEnd then
    copyRun src dst i iEnd k
  else
    mergeStep cmp src dst i iEnd j jEnd k

-- Dispatches on comparator result; separated out to avoid match-inside-else.
mergeStep : (a -> a -> <e> Ordering) ->
  Array a ->
  Array a ->
  Int ->
  Int ->
  Int ->
  Int ->
  Int ->
  <e> Unit
mergeStep cmp src dst i iEnd j jEnd k =
  match cmp (arrayGetUnsafe i src) (arrayGetUnsafe j src)
    Gt =>
      let _ = arraySetUnsafe k (arrayGetUnsafe j src) dst
      mergeRun cmp src dst i iEnd (j + 1) jEnd (k + 1)
    _ =>
      let _ = arraySetUnsafe k (arrayGetUnsafe i src) dst
      mergeRun cmp src dst (i + 1) iEnd j jEnd (k + 1)

-- Copies `src[i, iEnd)` into `dst` from index `k` on.
copyRun : Array a -> Array a -> Int -> Int -> Int -> Unit
copyRun src dst i iEnd k =
  if i >= iEnd then
    ()
  else
    let _ = arraySetUnsafe k (arrayGetUnsafe i src) dst
    copyRun src dst (i + 1) iEnd (k + 1)

-- # Searching

-- `fold`, `foldRight`, `any`, `all` are reachable via the Foldable impl in
-- `stdlib/core.mdk`.

{- | The first element satisfying `pred`, or `None`.

   > find (x => x > 1) (fromList [1, 2, 3])
   Some 2 -}
export
find : (a -> <e> Bool) -> Array a -> <e> Option a
find pred arr = findGo pred arr 0 (arrayLength arr)

findGo : (a -> <e> Bool) -> Array a -> Int -> Int -> <e> Option a
findGo pred arr i n =
  if i >= n then
    None
  else if pred (arrayGetUnsafe i arr) then
    Some (arrayGetUnsafe i arr)
  else
    findGo pred arr (i + 1) n

{- | The index of the first element satisfying `pred`, or `None`.

   > findIndex (x => x > 2) (fromList [1, 2, 3])
   Some 2 -}
export
findIndex : (a -> <e> Bool) -> Array a -> <e> Option Int
findIndex pred arr = findIndexGo pred arr 0 (arrayLength arr)

findIndexGo : (a -> <e> Bool) -> Array a -> Int -> Int -> <e> Option Int
findIndexGo pred arr i n =
  if i >= n then
    None
  else if pred (arrayGetUnsafe i arr) then
    Some i
  else
    findIndexGo pred arr (i + 1) n

{- `elem`, `sum`, and `product` are *not* defined here either: the generic
   `Foldable` versions in core (`elem : (Foldable t, Eq a) => …`,
   `sum`/`product : (Foldable t, Num a) => …`) dispatch over `impl Foldable
   Array` and fold through the same tight loop, so the array-specialised
   copies were pure redundancy.  Doctests pinning the dispatch:

   > elem 2 (fromList [1, 2, 3])
   True
   > sum (fromList [1, 2, 3, 4])
   10
   > product (fromList [1, 2, 3, 4])
   24 -}

{- `maximum`/`minimum` are *not* defined here: the generic `(Foldable t,
   Ord a) => t a -> Option a` versions in core dispatch over `impl Foldable
   Array`, so they already work on arrays.  Doctests pinning that:

   > maximum (fromList [3, 1, 2])
   Some 3
   > minimum (fromList [3, 1, 2])
   Some 1 -}

-- # Indexed iteration

-- `arrayGetUnsafe` is internal-only, and the bounds-checked `get` returns an
-- `Option` whose `None` arm a caller walking a known-good index range can
-- never hit, forcing an unreachable match at every call site.  These give
-- bounds-safe indexed access without either: the index is threaded by
-- construction, never taken from caller-supplied input.  Argument/callback
-- order follows `List.mapWithIndex` (index before element) and
-- `Foldable.fold` (accumulator, then element).

{- | A left fold whose step also receives each element's index.

   > foldWithIndex (acc i x => acc + i * x) 0 (fromList [10, 20, 30])
   80 -}
export
foldWithIndex : (b -> Int -> a -> <e> b) -> b -> Array a -> <e> b
foldWithIndex f z arr = foldWithIndexGo f arr 0 (arrayLength arr) z

-- > foldWithIndex (acc i x => (i, x) :: acc) [] (fromList ([] : List Int))
-- []

foldWithIndexGo : (b -> Int -> a -> <e> b) ->
  Array a ->
  Int ->
  Int ->
  b ->
  <e> b
foldWithIndexGo f arr i n acc =
  if i >= n then
    acc
  else
    foldWithIndexGo f arr (i + 1) n (f acc i (arrayGetUnsafe i arr))

{- | Runs `f` on each index and element in order, for its effect.

   > let acc = Ref [] in let _ = forEachWithIndex (i x => acc := (i, x) :: !acc) (fromList [7, 8, 9]) in !acc
   [(2, 9), (1, 8), (0, 7)] -}
export
forEachWithIndex : (Int -> a -> <e> Unit) -> Array a -> <e> Unit
forEachWithIndex f arr = forEachWithIndexGo f arr 0 (arrayLength arr)

forEachWithIndexGo : (Int -> a -> <e> Unit) -> Array a -> Int -> Int -> <e> Unit
forEachWithIndexGo f arr i n =
  if i >= n then
    ()
  else
    let _ = f i (arrayGetUnsafe i arr)
    forEachWithIndexGo f arr (i + 1) n

{- | Like `map`, with `f` also receiving each element's index.

   > toList (mapWithIndex (i x => i * x) (fromList [1, 2, 3]))
   [0, 2, 6] -}
export
mapWithIndex : (Int -> a -> <e> b) -> Array a -> <e> Array b
mapWithIndex f arr =
  arrayMakeWith (arrayLength arr) (i => f i (arrayGetUnsafe i arr))

-- > toList (mapWithIndex (i x => i + x) (fromList ([] : List Int)))
-- []

-- ── Typeclass impls ─────────────────────────────────────────────────────

-- The `Mappable`, `Foldable`, `Semigroup` and `Monoid` impls for `Array`, like
-- `Eq`/`Debug`/`Index`, live in `stdlib/core.mdk` (the prelude), so
-- `length (toChars s)` and `map f arr` work without an `import array`.
-- `impl Eq (Array a)` lives in core for the same reason: `deriving (Eq)` over
-- an array field builds without an `import array`.

-- ── Properties (executed by `medaka test`) ──────────────────────────────

-- Ascending-order check for props below.
isSortedArr : Ord a => Array a -> Bool
isSortedArr arr = isSortedArrGo arr 0 (arrayLength arr)

isSortedArrGo : Ord a => Array a -> Int -> Int -> Bool
isSortedArrGo arr i n
  | i >= n - 1 = True
  | lte (arrayGetUnsafe i arr) (arrayGetUnsafe (i + 1) arr) =
    isSortedArrGo arr (i + 1) n
  | otherwise = False

prop "sortBy ascending and length-preserving" (xs : List Int) =
  let arr = fromList xs
  let sorted = sortBy compare arr
  isSortedArr sorted && length sorted == length arr

prop "sortBy idempotent" (xs : List Int) =
  let arr = fromList xs
  let sorted = sortBy compare arr
  eq sorted (sortBy compare sorted)

prop "sortBy stable: equal keys preserve original order" (xs : List Int) =
  let arr = fromList (map (x => (0, x)) xs)
  let sorted = sortBy ((k1, _) (k2, _) => compare k1 k2) arr
  eq (toList (map snd sorted)) xs

prop "makeWith length" (n : Int) =
  let n' = if n < 0 then 0 - n else n
  length (makeWith n' (i => i)) == n'

prop "makeWith element at index 0" (n : Int) =
  let n' = if n <= 0 then 1 else n
  arrayGetUnsafe 0 (makeWith n' (i => i * 3 + 7)) == 7

{- `foldWithIndex`/`forEachWithIndex` are checked against an oracle built
   from primitives with no shared implementation with them: `range` (a
   separate index-generation path) paired with the existing array `zip` and
   `Foldable.fold`, not against a restatement of `foldWithIndex` itself. -}

prop "foldWithIndex matches fold over zip with range" (xs : List Int) =
  let arr = fromList xs
  let viaIndex = foldWithIndex (acc i x => (i, x) :: acc) [] arr
  let viaZip =
    fold (acc pair => pair :: acc) [] (zip (range 0 (length arr)) arr)
  eq viaIndex viaZip

prop "forEachWithIndex visits every index once, in order, matching zip with range" (xs : List Int) =
  let arr = fromList xs
  let seen = Ref []
  let _ = forEachWithIndex (i x => seen := (i, x) :: !seen) arr
  let viaZip =
    fold (acc pair => pair :: acc) [] (zip (range 0 (length arr)) arr)
  eq !seen viaZip

-- LAW: `mapWithIndex` is `map` that also sees the index.  Three clauses pin
-- it: it agrees with `map` on an index-ignoring callback, it hands the
-- callback exactly the indices 0..n-1 in order (this is what fixes the
-- `(i x)` argument order, not `(x i)`), and it agrees with its own family
-- sibling `foldWithIndex` on the same callback.
prop "mapWithIndex with an index-ignoring callback is map" (xs : List Int) =
  let arr = fromList xs
  eq (mapWithIndex (_ x => x + 1) arr) (map (x => x + 1) arr)

prop "mapWithIndex hands the callback 0..n-1 in order" (xs : List Int) =
  let arr = fromList xs
  eq (mapWithIndex (i _ => i) arr) (range 0 (length arr))

prop "mapWithIndex agrees with zipWith over range" (xs : List Int) =
  let arr = fromList xs
  eq
    (mapWithIndex (i x => i * 10 + x) arr)
    (zipWith (i x => i * 10 + x) (range 0 (length arr)) arr)

-- Pairs of (key, original index) must come out ordered by key, and by index
-- within each key: that is what stability means for a sort by key alone.
isStableKeyedArr : Array (Int, Int) -> Int -> Bool
isStableKeyedArr arr i
  | i >= arrayLength arr - 1 = True
  | otherwise =
    let a = arrayGetUnsafe i arr
    let b = arrayGetUnsafe (i + 1) arr
    if fst a < fst b || fst a == fst b && snd a < snd b then
      isStableKeyedArr arr (i + 1)
    else
      False

prop "sortBy is stable on keys with many duplicates" (xs : List Int) =
  let tagged = zip (map (x => x % 3) (fromList xs)) (range 0 (length xs))
  isStableKeyedArr (sortBy ((k1, _) (k2, _) => compare k1 k2) tagged) 0

prop "sort of already-sorted, reversed, and duplicate-heavy input" (xs : List Int) =
  let arr = fromList xs
  let sorted = sort arr
  let dups = map (x => x % 4) arr
  eq (sort sorted) sorted
    && eq (sort (reverse arr)) sorted
    && isSortedArr (sort dups)
    && length (sort dups) == length arr

prop "sortOn agrees with sortBy on the same key" (xs : List Int) =
  let arr = fromList xs
  eq (sortOn (x => x % 5) arr) (sortBy (a b => compare (a % 5) (b % 5)) arr)

prop "filter agrees with List filter" (xs : List Int) =
  let arr = fromList xs
  eq (toList (filter (x => x % 3 == 0) arr)) (filter (x => x % 3 == 0) xs)

prop "filterMap agrees with List filterMap" (xs : List Int) =
  let arr = fromList xs
  let f = x => if x % 3 == 0 then Some (x * 2) else None
  eq (toList (filterMap f arr)) (filterMap f xs)

prop "take, drop and sliceClamped agree with an index filter" (xs : List Int) (lo : Int) (hi : Int) =
  let arr = fromList xs
  let pairs = toList (zip (range 0 (length arr)) arr)
  let inRange = p => fst p >= lo && fst p < hi
  eq (toList (sliceClamped lo hi arr)) (map snd (filter inRange pairs))
    && eq (toList (take lo arr)) (map snd (filter (p => fst p < lo) pairs))
    && eq (toList (drop lo arr)) (map snd (filter (p => fst p >= lo) pairs))
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Ordering" true) (mem "Ord" false) (mem "Debug" false) (mem "Display" false) (mem "Foldable" false) (mem "Mappable" false) (mem "Filterable" false) (mem "Semigroup" false) (mem "Monoid" false) (mem "Option" false))))
(DTypeSig true "singleton" (TyFun (TyVar "a") (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "singleton" ((PVar "x")) (EArrayLit (EVar "x")))
(DTypeSig true "make" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyApp (TyCon "Array") (TyVar "a")))))
(DFunDef false "make" ((PVar "n") (PVar "x")) (EApp (EApp (EVar "arrayMake") (EVar "n")) (EVar "x")))
(DTypeSig true "makeWith" (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyVar "a"))) (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "a"))))))
(DFunDef false "makeWith" ((PVar "n") (PVar "f")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EArrayLit) (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (EVar "f"))))
(DTypeSig true "fromList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "fromList" ((PVar "xs")) (EApp (EVar "arrayFromList") (EVar "xs")))
(DTypeSig true "range" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int")))))
(DFunDef false "range" ((PVar "lo") (PVar "hi")) (EApp (EApp (EVar "arrayMakeWith") (EIf (EBinOp ">" (EVar "hi") (EVar "lo")) (EBinOp "-" (EVar "hi") (EVar "lo")) (ELit (LInt 0)))) (ELam ((PVar "_s")) (EBinOp "+" (EVar "lo") (EVar "_s")))))
(DTypeSig true "copy" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "copy" ((PVar "arr")) (EApp (EVar "arrayCopy") (EVar "arr")))
(DTypeSig true "get" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "get" ((PVar "i") (PVar "arr")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr")))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))))
(DTypeSig true "first" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "first" ((PVar "arr")) (EApp (EApp (EVar "get") (ELit (LInt 0))) (EVar "arr")))
(DTypeSig true "last" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "last" ((PVar "arr")) (EApp (EApp (EVar "get") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EVar "arr")))
(DTypeSig true "reverse" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "reverse" ((PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EBinOp "-" (EVar "n") (ELit (LInt 1))) (EVar "i"))) (EVar "arr")))))))
(DTypeSig true "sliceClamped" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))))
(DFunDef false "sliceClamped" ((PVar "lo") (PVar "hi") (PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoLet false false (PVar "lo'") (EIf (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EApp (EVar "min") (EVar "lo")) (EVar "n")))) (DoLet false false (PVar "hi'") (EIf (EBinOp "<" (EVar "hi") (EVar "lo'")) (EVar "lo'") (EApp (EApp (EVar "min") (EVar "hi")) (EVar "n")))) (DoLet false false (PVar "m") (EBinOp "-" (EVar "hi'") (EVar "lo'"))) (DoExpr (EIf (EBinOp "<=" (EVar "m") (ELit (LInt 0))) (EArrayLit) (EBlock (DoLet false false (PVar "out") (EApp (EApp (EVar "arrayMake") (EVar "m")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "lo'")) (EVar "arr")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "arr")) (EVar "lo'")) (EVar "out")) (ELit (LInt 0))) (EVar "m"))) (DoExpr (EVar "out")))))))
(DTypeSig true "take" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a")))))
(DFunDef false "take" ((PVar "n") (PVar "arr")) (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 0))) (EVar "n")) (EVar "arr")))
(DTypeSig true "drop" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a")))))
(DFunDef false "drop" ((PVar "n") (PVar "arr")) (EApp (EApp (EApp (EVar "sliceClamped") (EVar "n")) (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "arr")))
(DTypeSig true "concat" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Array") (TyVar "a"))) (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "concat" ((PVar "arrs")) (EBlock (DoLet false false (PVar "outer") (EApp (EVar "arrayLength") (EVar "arrs"))) (DoLet false false (PVar "total") (EApp (EApp (EApp (EApp (EVar "concatTotal") (EVar "arrs")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "outer"))) (DoExpr (EIf (EBinOp "<=" (EVar "total") (ELit (LInt 0))) (EArrayLit) (EBlock (DoLet false false (PVar "out") (EApp (EApp (EVar "arrayMake") (EVar "total")) (EApp (EApp (EApp (EApp (EVar "concatLookup") (EVar "arrs")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "outer")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "concatBlitAll") (EVar "arrs")) (EVar "out")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "outer"))))))))
(DTypeSig false "concatBlitAll" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Array") (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyVar "a"))))))))
(DFunDef false "concatBlitAll" ((PVar "arrs") (PVar "out") (PVar "k") (PVar "dstOff") (PVar "outer")) (EIf (EBinOp ">=" (EVar "k") (EVar "outer")) (EVar "out") (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arrs"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "inner"))) (DoExpr (EIf (EBinOp "<=" (EVar "len") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EVar "concatBlitAll") (EVar "arrs")) (EVar "out")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "dstOff")) (EVar "outer")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "inner")) (ELit (LInt 0))) (EVar "out")) (EVar "dstOff")) (EVar "len"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "concatBlitAll") (EVar "arrs")) (EVar "out")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EBinOp "+" (EVar "dstOff") (EVar "len"))) (EVar "outer")))))))))
(DTypeSig false "concatTotal" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Array") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "concatTotal" ((PVar "arrs") (PVar "i") (PVar "acc") (PVar "outer")) (EIf (EBinOp ">=" (EVar "i") (EVar "outer")) (EVar "acc") (EApp (EApp (EApp (EApp (EVar "concatTotal") (EVar "arrs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (EApp (EVar "arrayLength") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arrs"))))) (EVar "outer"))))
(DTypeSig false "concatLookup" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Array") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a"))))))
(DFunDef false "concatLookup" ((PVar "arrs") (PVar "target") (PVar "k") (PVar "outer")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arrs"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "inner"))) (DoExpr (EIf (EBinOp "<" (EVar "target") (EVar "len")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "target")) (EVar "inner")) (EApp (EApp (EApp (EApp (EVar "concatLookup") (EVar "arrs")) (EBinOp "-" (EVar "target") (EVar "len"))) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "outer"))))))
(DTypeSig true "zip" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "b")) (TyApp (TyCon "Array") (TyTuple (TyVar "a") (TyVar "b"))))))
(DFunDef false "zip" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "min") (EApp (EVar "arrayLength") (EVar "a"))) (EApp (EVar "arrayLength") (EVar "b")))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (ETuple (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "b"))))))))
(DTypeSig true "zipWith" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "c")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "b")) (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "c")))))))
(DFunDef false "zipWith" ((PVar "f") (PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "min") (EApp (EVar "arrayLength") (EVar "a"))) (EApp (EVar "arrayLength") (EVar "b")))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "b"))))))))
(DTypeSig true "unzip" (TyFun (TyApp (TyCon "Array") (TyTuple (TyVar "a") (TyVar "b"))) (TyTuple (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "b")))))
(DFunDef false "unzip" ((PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (ETuple (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))) (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EVar "snd") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))))))))
(DImpl true "Filterable" ((TyCon "Array")) () ((im "filter" ((PVar "p") (PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EArrayLit) (EBlock (DoLet false false (PVar "buf") (EApp (EApp (EVar "arrayMake") (EVar "n")) (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EVar "filterFinish") (EVar "buf")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "filterGo") (EVar "p")) (EVar "arr")) (EVar "buf")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "n"))) (EVar "n")))))))) (im "filterMap" ((PVar "f") (PVar "arr")) (EApp (EApp (EApp (EApp (EVar "filterMapFrom") (EVar "f")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))))
(DTypeSig false "filterGo" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Int")))))))))
(DFunDef false "filterGo" ((PVar "p") (PVar "arr") (PVar "buf") (PVar "i") (PVar "k") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "k") (EBlock (DoLet false false (PVar "x") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (DoExpr (EIf (EApp (EVar "p") (EVar "x")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "k")) (EVar "x")) (EVar "buf"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "filterGo") (EVar "p")) (EVar "arr")) (EVar "buf")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "n")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "filterGo") (EVar "p")) (EVar "arr")) (EVar "buf")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "k")) (EVar "n")))))))
(DTypeSig false "filterFinish" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyVar "a"))))))
(DFunDef false "filterFinish" ((PVar "buf") (PVar "k") (PVar "n")) (EIf (EBinOp "<=" (EVar "k") (ELit (LInt 0))) (EArrayLit) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EVar "buf") (EBlock (DoLet false false (PVar "out") (EApp (EApp (EVar "arrayMake") (EVar "k")) (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "buf")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "buf")) (ELit (LInt 0))) (EVar "out")) (ELit (LInt 0))) (EVar "k"))) (DoExpr (EVar "out"))))))
(DTypeSig false "filterMapFrom" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "b")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "b"))))))))
(DFunDef false "filterMapFrom" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EArrayLit) (EMatch (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "filterMapFrom") (EVar "f")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (arm (PCon "Some" (PVar "y")) () (EBlock (DoLet false false (PVar "buf") (EApp (EApp (EVar "arrayMake") (EVar "n")) (EVar "y"))) (DoExpr (EApp (EApp (EApp (EVar "filterFinish") (EVar "buf")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "filterMapGo") (EVar "f")) (EVar "arr")) (EVar "buf")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (ELit (LInt 1)))) (EVar "n"))))))))
(DTypeSig false "filterMapGo" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "b")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "b")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Int")))))))))
(DFunDef false "filterMapGo" ((PVar "f") (PVar "arr") (PVar "buf") (PVar "i") (PVar "n") (PVar "k")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "k") (EMatch (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (arm (PCon "Some" (PVar "y")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "k")) (EVar "y")) (EVar "buf"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "filterMapGo") (EVar "f")) (EVar "arr")) (EVar "buf")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "+" (EVar "k") (ELit (LInt 1))))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "filterMapGo") (EVar "f")) (EVar "arr")) (EVar "buf")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "k"))))))
(DTypeSig true "setInPlace" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "setInPlace" ((PVar "i") (PVar "x") (PVar "arr")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr")))) (EApp (EVar "indexErrorAt") (EVar "i")) (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "x")) (EVar "arr"))))
(DTypeSig true "swap" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "swap" ((PVar "i") (PVar "j") (PVar "arr")) (EBlock (DoLet false false (PVar "xi") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (DoLet false false (PVar "xj") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "xj")) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "j")) (EVar "xi")) (EVar "arr")))))
(DTypeSig true "fill" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "fill" ((PVar "x") (PVar "arr")) (EApp (EApp (EVar "arrayFill") (EVar "x")) (EVar "arr")))
(DTypeSig true "blit" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit")))))))
(DFunDef false "blit" ((PVar "src") (PVar "srcOff") (PVar "dst") (PVar "dstOff") (PVar "len")) (EIf (EBinOp "<" (EVar "len") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "Array.blit: negative length"))) (EIf (EBinOp "<" (EVar "srcOff") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "Array.blit: negative srcOff"))) (EIf (EBinOp "<" (EVar "dstOff") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "Array.blit: negative dstOff"))) (EIf (EBinOp ">" (EVar "len") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "src")) (EVar "srcOff"))) (EApp (EVar "panic") (ELit (LString "Array.blit: source out of bounds"))) (EIf (EBinOp ">" (EVar "len") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "dst")) (EVar "dstOff"))) (EApp (EVar "panic") (ELit (LString "Array.blit: destination out of bounds"))) (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "src")) (EVar "srcOff")) (EVar "dst")) (EVar "dstOff")) (EVar "len"))))))))
(DTypeSig true "sortInPlaceBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyCon "Unit")))))
(DFunDef false "sortInPlaceBy" ((PVar "cmp") (PVar "arr")) (EBlock (DoLet false false (PVar "sorted") (EApp (EApp (EVar "sortBy") (EVar "cmp")) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "sorted")) (ELit (LInt 0))) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))))
(DTypeSig true "sortInPlace" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "sortInPlace" ((PVar "arr")) (EApp (EApp (EVar "sortInPlaceBy") (EVar "compare")) (EVar "arr")))
(DTypeSig true "sortBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "a"))))))
(DFunDef false "sortBy" ((PVar "cmp") (PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 1))) (EApp (EVar "arrayCopy") (EVar "arr")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "arrayCopy") (EVar "arr"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "sortRuns") (EVar "cmp")) (EVar "src")) (EVar "n")) (ELit (LInt 8))) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "mergePasses") (EVar "cmp")) (EVar "src")) (EApp (EApp (EVar "arrayMake") (EVar "n")) (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "arr")))) (EVar "n")) (ELit (LInt 8)))))))))
(DTypeSig true "sort" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a")))))
(DFunDef false "sort" ((PVar "arr")) (EApp (EApp (EVar "sortBy") (EVar "compare")) (EVar "arr")))
(DTypeSig true "sortOn" (TyConstrained ((cstr "Ord" (TyVar "b"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "a")))))))
(DFunDef false "sortOn" ((PVar "key") (PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoLet false false (PVar "keys") (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EVar "key") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))))) (DoLet false false (PVar "order") (EApp (EApp (EVar "sortBy") (ELam ((PVar "i") (PVar "j")) (EApp (EApp (EVar "compare") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "keys"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "keys"))))) (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EVar "i"))))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "order"))) (EVar "arr")))))))
(DTypeSig false "sortRuns" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit"))))))))
(DFunDef false "sortRuns" ((PVar "cmp") (PVar "a") (PVar "n") (PVar "w") (PVar "lo")) (EIf (EBinOp ">=" (EVar "lo") (EVar "n")) (ELit LUnit) (EBlock (DoLet false false (PVar "hi") (EApp (EApp (EVar "min") (EBinOp "+" (EVar "lo") (EVar "w"))) (EVar "n"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "insertionRun") (EVar "cmp")) (EVar "a")) (EVar "lo")) (EVar "hi")) (EBinOp "+" (EVar "lo") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "sortRuns") (EVar "cmp")) (EVar "a")) (EVar "n")) (EVar "w")) (EVar "hi"))))))
(DTypeSig false "insertionRun" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit"))))))))
(DFunDef false "insertionRun" ((PVar "cmp") (PVar "a") (PVar "lo") (PVar "hi") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "hi")) (ELit LUnit) (EBlock (DoLet false false (PVar "x") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "insertionShift") (EVar "cmp")) (EVar "a")) (EVar "lo")) (EVar "i")) (EVar "x"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "insertionRun") (EVar "cmp")) (EVar "a")) (EVar "lo")) (EVar "hi")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig false "insertionShift" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Unit"))))))))
(DFunDef false "insertionShift" ((PVar "cmp") (PVar "a") (PVar "lo") (PVar "j") (PVar "x")) (EIf (EBinOp "<=" (EVar "j") (EVar "lo")) (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "j")) (EVar "x")) (EVar "a")) (EIf (EApp (EApp (EApp (EVar "isNotGt") (EVar "cmp")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "j") (ELit (LInt 1)))) (EVar "a"))) (EVar "x")) (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "j")) (EVar "x")) (EVar "a")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "j")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "j") (ELit (LInt 1)))) (EVar "a"))) (EVar "a"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "insertionShift") (EVar "cmp")) (EVar "a")) (EVar "lo")) (EBinOp "-" (EVar "j") (ELit (LInt 1)))) (EVar "x")))))))
(DTypeSig false "mergePasses" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "a")))))))))
(DFunDef false "mergePasses" ((PVar "cmp") (PVar "src") (PVar "dst") (PVar "n") (PVar "width")) (EIf (EBinOp ">=" (EVar "width") (EVar "n")) (EVar "src") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeRuns") (EVar "cmp")) (EVar "src")) (EVar "dst")) (EVar "n")) (EVar "width")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "mergePasses") (EVar "cmp")) (EVar "dst")) (EVar "src")) (EVar "n")) (EBinOp "*" (EVar "width") (ELit (LInt 2))))))))
(DTypeSig false "mergeRuns" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit")))))))))
(DFunDef false "mergeRuns" ((PVar "cmp") (PVar "src") (PVar "dst") (PVar "n") (PVar "width") (PVar "lo")) (EIf (EBinOp ">=" (EVar "lo") (EVar "n")) (ELit LUnit) (EBlock (DoLet false false (PVar "mid") (EApp (EApp (EVar "min") (EBinOp "+" (EVar "lo") (EVar "width"))) (EVar "n"))) (DoLet false false (PVar "hi") (EApp (EApp (EVar "min") (EBinOp "+" (EBinOp "+" (EVar "lo") (EVar "width")) (EVar "width"))) (EVar "n"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergePair") (EVar "cmp")) (EVar "src")) (EVar "dst")) (EVar "lo")) (EVar "mid")) (EVar "hi"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeRuns") (EVar "cmp")) (EVar "src")) (EVar "dst")) (EVar "n")) (EVar "width")) (EVar "hi"))))))
(DTypeSig false "mergePair" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit")))))))))
(DFunDef false "mergePair" ((PVar "cmp") (PVar "src") (PVar "dst") (PVar "lo") (PVar "mid") (PVar "hi")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "mid") (EVar "hi")) (EApp (EApp (EApp (EVar "isNotGt") (EVar "cmp")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "mid") (ELit (LInt 1)))) (EVar "src"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "mid")) (EVar "src")))) (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "src")) (EVar "lo")) (EVar "dst")) (EVar "lo")) (EBinOp "-" (EVar "hi") (EVar "lo"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeRun") (EVar "cmp")) (EVar "src")) (EVar "dst")) (EVar "lo")) (EVar "mid")) (EVar "mid")) (EVar "hi")) (EVar "lo"))))
(DTypeSig false "isNotGt" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))))))
(DFunDef false "isNotGt" ((PVar "cmp") (PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "cmp") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True"))))
(DTypeSig false "mergeRun" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit")))))))))))
(DFunDef false "mergeRun" ((PVar "cmp") (PVar "src") (PVar "dst") (PVar "i") (PVar "iEnd") (PVar "j") (PVar "jEnd") (PVar "k")) (EIf (EBinOp ">=" (EVar "i") (EVar "iEnd")) (EApp (EApp (EApp (EApp (EApp (EVar "copyRun") (EVar "src")) (EVar "dst")) (EVar "j")) (EVar "jEnd")) (EVar "k")) (EIf (EBinOp ">=" (EVar "j") (EVar "jEnd")) (EApp (EApp (EApp (EApp (EApp (EVar "copyRun") (EVar "src")) (EVar "dst")) (EVar "i")) (EVar "iEnd")) (EVar "k")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeStep") (EVar "cmp")) (EVar "src")) (EVar "dst")) (EVar "i")) (EVar "iEnd")) (EVar "j")) (EVar "jEnd")) (EVar "k")))))
(DTypeSig false "mergeStep" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit")))))))))))
(DFunDef false "mergeStep" ((PVar "cmp") (PVar "src") (PVar "dst") (PVar "i") (PVar "iEnd") (PVar "j") (PVar "jEnd") (PVar "k")) (EMatch (EApp (EApp (EVar "cmp") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "src"))) (arm (PCon "Gt") () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "k")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "src"))) (EVar "dst"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeRun") (EVar "cmp")) (EVar "src")) (EVar "dst")) (EVar "i")) (EVar "iEnd")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EVar "jEnd")) (EBinOp "+" (EVar "k") (ELit (LInt 1))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "k")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src"))) (EVar "dst"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeRun") (EVar "cmp")) (EVar "src")) (EVar "dst")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "iEnd")) (EVar "j")) (EVar "jEnd")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))))))))
(DTypeSig false "copyRun" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit")))))))
(DFunDef false "copyRun" ((PVar "src") (PVar "dst") (PVar "i") (PVar "iEnd") (PVar "k")) (EIf (EBinOp ">=" (EVar "i") (EVar "iEnd")) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "k")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src"))) (EVar "dst"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "copyRun") (EVar "src")) (EVar "dst")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "iEnd")) (EBinOp "+" (EVar "k") (ELit (LInt 1))))))))
(DTypeSig true "find" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "a"))))))
(DFunDef false "find" ((PVar "pred") (PVar "arr")) (EApp (EApp (EApp (EApp (EVar "findGo") (EVar "pred")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "findGo" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "a"))))))))
(DFunDef false "findGo" ((PVar "pred") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EApp (EVar "pred") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EApp (EApp (EVar "findGo") (EVar "pred")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig true "findIndex" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "findIndex" ((PVar "pred") (PVar "arr")) (EApp (EApp (EApp (EApp (EVar "findIndexGo") (EVar "pred")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "findIndexGo" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "findIndexGo" ((PVar "pred") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EApp (EVar "pred") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EVar "Some") (EVar "i")) (EApp (EApp (EApp (EApp (EVar "findIndexGo") (EVar "pred")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig true "foldWithIndex" (TyFun (TyFun (TyVar "b") (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldWithIndex" ((PVar "f") (PVar "z") (PVar "arr")) (EApp (EApp (EApp (EApp (EApp (EVar "foldWithIndexGo") (EVar "f")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "z")))
(DTypeSig false "foldWithIndexGo" (TyFun (TyFun (TyVar "b") (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b"))))))))
(DFunDef false "foldWithIndexGo" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EApp (EApp (EApp (EApp (EApp (EVar "foldWithIndexGo") (EVar "f")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EApp (EApp (EVar "f") (EVar "acc")) (EVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))))
(DTypeSig true "forEachWithIndex" (TyFun (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Unit")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyCon "Unit")))))
(DFunDef false "forEachWithIndex" ((PVar "f") (PVar "arr")) (EApp (EApp (EApp (EApp (EVar "forEachWithIndexGo") (EVar "f")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "forEachWithIndexGo" (TyFun (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Unit")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit")))))))
(DFunDef false "forEachWithIndexGo" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EApp (EVar "f") (EVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "forEachWithIndexGo") (EVar "f")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))))))
(DTypeSig true "mapWithIndex" (TyFun (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "b"))))))
(DFunDef false "mapWithIndex" ((PVar "f") (PVar "arr")) (EApp (EApp (EVar "arrayMakeWith") (EApp (EVar "arrayLength") (EVar "arr"))) (ELam ((PVar "i")) (EApp (EApp (EVar "f") (EVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))))
(DTypeSig false "isSortedArr" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "isSortedArr" ((PVar "arr")) (EApp (EApp (EApp (EVar "isSortedArrGo") (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "isSortedArrGo" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "isSortedArrGo" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "True") (EIf (EApp (EApp (EVar "lte") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EApp (EVar "isSortedArrGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DProp false "sortBy ascending and length-preserving" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "sorted") (EApp (EApp (EVar "sortBy") (EVar "compare")) (EVar "arr"))) (DoExpr (EBinOp "&&" (EApp (EVar "isSortedArr") (EVar "sorted")) (EBinOp "==" (EApp (EVar "length") (EVar "sorted")) (EApp (EVar "length") (EVar "arr")))))))
(DProp false "sortBy idempotent" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "sorted") (EApp (EApp (EVar "sortBy") (EVar "compare")) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "eq") (EVar "sorted")) (EApp (EApp (EVar "sortBy") (EVar "compare")) (EVar "sorted"))))))
(DProp false "sortBy stable: equal keys preserve original order" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EApp (EApp (EVar "map") (ELam ((PVar "x")) (ETuple (ELit (LInt 0)) (EVar "x")))) (EVar "xs")))) (DoLet false false (PVar "sorted") (EApp (EApp (EVar "sortBy") (ELam ((PTuple (PVar "k1") PWild) (PTuple (PVar "k2") PWild)) (EApp (EApp (EVar "compare") (EVar "k1")) (EVar "k2")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "eq") (EApp (EVar "toList") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "sorted")))) (EVar "xs")))))
(DProp false "makeWith length" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "n'") (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n"))) (DoExpr (EBinOp "==" (EApp (EVar "length") (EApp (EApp (EVar "makeWith") (EVar "n'")) (ELam ((PVar "i")) (EVar "i")))) (EVar "n'")))))
(DProp false "makeWith element at index 0" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "n'") (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ELit (LInt 1)) (EVar "n"))) (DoExpr (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EApp (EVar "makeWith") (EVar "n'")) (ELam ((PVar "i")) (EBinOp "+" (EBinOp "*" (EVar "i") (ELit (LInt 3))) (ELit (LInt 7)))))) (ELit (LInt 7))))))
(DProp false "foldWithIndex matches fold over zip with range" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "viaIndex") (EApp (EApp (EApp (EVar "foldWithIndex") (ELam ((PVar "acc") (PVar "i") (PVar "x")) (EBinOp "::" (ETuple (EVar "i") (EVar "x")) (EVar "acc")))) (EListLit)) (EVar "arr"))) (DoLet false false (PVar "viaZip") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "pair")) (EBinOp "::" (EVar "pair") (EVar "acc")))) (EListLit)) (EApp (EApp (EVar "zip") (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EVar "length") (EVar "arr")))) (EVar "arr")))) (DoExpr (EApp (EApp (EVar "eq") (EVar "viaIndex")) (EVar "viaZip")))))
(DProp false "forEachWithIndex visits every index once, in order, matching zip with range" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "seen") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "forEachWithIndex") (ELam ((PVar "i") (PVar "x")) (EApp (EApp (EVar "setRef") (EVar "seen")) (EBinOp "::" (ETuple (EVar "i") (EVar "x")) (EUnOp "!" (EVar "seen")))))) (EVar "arr"))) (DoLet false false (PVar "viaZip") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "pair")) (EBinOp "::" (EVar "pair") (EVar "acc")))) (EListLit)) (EApp (EApp (EVar "zip") (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EVar "length") (EVar "arr")))) (EVar "arr")))) (DoExpr (EApp (EApp (EVar "eq") (EUnOp "!" (EVar "seen"))) (EVar "viaZip")))))
(DProp false "mapWithIndex with an index-ignoring callback is map" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "eq") (EApp (EApp (EVar "mapWithIndex") (ELam (PWild (PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 1))))) (EVar "arr"))) (EApp (EApp (EVar "map") (ELam ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 1))))) (EVar "arr"))))))
(DProp false "mapWithIndex hands the callback 0..n-1 in order" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "eq") (EApp (EApp (EVar "mapWithIndex") (ELam ((PVar "i") PWild) (EVar "i"))) (EVar "arr"))) (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EVar "length") (EVar "arr")))))))
(DProp false "mapWithIndex agrees with zipWith over range" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "eq") (EApp (EApp (EVar "mapWithIndex") (ELam ((PVar "i") (PVar "x")) (EBinOp "+" (EBinOp "*" (EVar "i") (ELit (LInt 10))) (EVar "x")))) (EVar "arr"))) (EApp (EApp (EApp (EVar "zipWith") (ELam ((PVar "i") (PVar "x")) (EBinOp "+" (EBinOp "*" (EVar "i") (ELit (LInt 10))) (EVar "x")))) (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EVar "length") (EVar "arr")))) (EVar "arr"))))))
(DTypeSig false "isStableKeyedArr" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "isStableKeyedArr" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EVar "True") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (DoLet false false (PVar "b") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EApp (EVar "fst") (EVar "a")) (EApp (EVar "fst") (EVar "b"))) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EVar "a")) (EApp (EVar "fst") (EVar "b"))) (EBinOp "<" (EApp (EVar "snd") (EVar "a")) (EApp (EVar "snd") (EVar "b"))))) (EApp (EApp (EVar "isStableKeyedArr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "False")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DProp false "sortBy is stable on keys with many duplicates" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "tagged") (EApp (EApp (EVar "zip") (EApp (EApp (EVar "map") (ELam ((PVar "x")) (EBinOp "%" (EVar "x") (ELit (LInt 3))))) (EApp (EVar "fromList") (EVar "xs")))) (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EVar "length") (EVar "xs"))))) (DoExpr (EApp (EApp (EVar "isStableKeyedArr") (EApp (EApp (EVar "sortBy") (ELam ((PTuple (PVar "k1") PWild) (PTuple (PVar "k2") PWild)) (EApp (EApp (EVar "compare") (EVar "k1")) (EVar "k2")))) (EVar "tagged"))) (ELit (LInt 0))))))
(DProp false "sort of already-sorted, reversed, and duplicate-heavy input" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "sorted") (EApp (EVar "sort") (EVar "arr"))) (DoLet false false (PVar "dups") (EApp (EApp (EVar "map") (ELam ((PVar "x")) (EBinOp "%" (EVar "x") (ELit (LInt 4))))) (EVar "arr"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "sort") (EVar "sorted"))) (EVar "sorted")) (EApp (EApp (EVar "eq") (EApp (EVar "sort") (EApp (EVar "reverse") (EVar "arr")))) (EVar "sorted"))) (EApp (EVar "isSortedArr") (EApp (EVar "sort") (EVar "dups")))) (EBinOp "==" (EApp (EVar "length") (EApp (EVar "sort") (EVar "dups"))) (EApp (EVar "length") (EVar "arr")))))))
(DProp false "sortOn agrees with sortBy on the same key" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "eq") (EApp (EApp (EVar "sortOn") (ELam ((PVar "x")) (EBinOp "%" (EVar "x") (ELit (LInt 5))))) (EVar "arr"))) (EApp (EApp (EVar "sortBy") (ELam ((PVar "a") (PVar "b")) (EApp (EApp (EVar "compare") (EBinOp "%" (EVar "a") (ELit (LInt 5)))) (EBinOp "%" (EVar "b") (ELit (LInt 5)))))) (EVar "arr"))))))
(DProp false "filter agrees with List filter" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "eq") (EApp (EVar "toList") (EApp (EApp (EVar "filter") (ELam ((PVar "x")) (EBinOp "==" (EBinOp "%" (EVar "x") (ELit (LInt 3))) (ELit (LInt 0))))) (EVar "arr")))) (EApp (EApp (EVar "filter") (ELam ((PVar "x")) (EBinOp "==" (EBinOp "%" (EVar "x") (ELit (LInt 3))) (ELit (LInt 0))))) (EVar "xs"))))))
(DProp false "filterMap agrees with List filterMap" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "f") (ELam ((PVar "x")) (EIf (EBinOp "==" (EBinOp "%" (EVar "x") (ELit (LInt 3))) (ELit (LInt 0))) (EApp (EVar "Some") (EBinOp "*" (EVar "x") (ELit (LInt 2)))) (EVar "None")))) (DoExpr (EApp (EApp (EVar "eq") (EApp (EVar "toList") (EApp (EApp (EVar "filterMap") (EVar "f")) (EVar "arr")))) (EApp (EApp (EVar "filterMap") (EVar "f")) (EVar "xs"))))))
(DProp false "take, drop and sliceClamped agree with an index filter" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "lo" (TyCon "Int")) (pp "hi" (TyCon "Int"))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "pairs") (EApp (EVar "toList") (EApp (EApp (EVar "zip") (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EVar "length") (EVar "arr")))) (EVar "arr")))) (DoLet false false (PVar "inRange") (ELam ((PVar "p")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "fst") (EVar "p")) (EVar "lo")) (EBinOp "<" (EApp (EVar "fst") (EVar "p")) (EVar "hi"))))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "toList") (EApp (EApp (EApp (EVar "sliceClamped") (EVar "lo")) (EVar "hi")) (EVar "arr")))) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EApp (EVar "filter") (EVar "inRange")) (EVar "pairs")))) (EApp (EApp (EVar "eq") (EApp (EVar "toList") (EApp (EApp (EVar "take") (EVar "lo")) (EVar "arr")))) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EApp (EVar "filter") (ELam ((PVar "p")) (EBinOp "<" (EApp (EVar "fst") (EVar "p")) (EVar "lo")))) (EVar "pairs"))))) (EApp (EApp (EVar "eq") (EApp (EVar "toList") (EApp (EApp (EVar "drop") (EVar "lo")) (EVar "arr")))) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EApp (EVar "filter") (ELam ((PVar "p")) (EBinOp ">=" (EApp (EVar "fst") (EVar "p")) (EVar "lo")))) (EVar "pairs"))))))))
# MARK
(DUse false (UseGroup ("core") ((mem "Ordering" true) (mem "Ord" false) (mem "Debug" false) (mem "Display" false) (mem "Foldable" false) (mem "Mappable" false) (mem "Filterable" false) (mem "Semigroup" false) (mem "Monoid" false) (mem "Option" false))))
(DTypeSig true "singleton" (TyFun (TyVar "a") (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "singleton" ((PVar "x")) (EArrayLit (EVar "x")))
(DTypeSig true "make" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyApp (TyCon "Array") (TyVar "a")))))
(DFunDef false "make" ((PVar "n") (PVar "x")) (EApp (EApp (EVar "arrayMake") (EVar "n")) (EVar "x")))
(DTypeSig true "makeWith" (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyVar "a"))) (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "a"))))))
(DFunDef false "makeWith" ((PVar "n") (PVar "f")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EArrayLit) (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (EVar "f"))))
(DTypeSig true "fromList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "fromList" ((PVar "xs")) (EApp (EVar "arrayFromList") (EVar "xs")))
(DTypeSig true "range" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int")))))
(DFunDef false "range" ((PVar "lo") (PVar "hi")) (EApp (EApp (EVar "arrayMakeWith") (EIf (EBinOp ">" (EVar "hi") (EVar "lo")) (EBinOp "-" (EVar "hi") (EVar "lo")) (ELit (LInt 0)))) (ELam ((PVar "_s")) (EBinOp "+" (EVar "lo") (EVar "_s")))))
(DTypeSig true "copy" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "copy" ((PVar "arr")) (EApp (EVar "arrayCopy") (EVar "arr")))
(DTypeSig true "get" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "get" ((PVar "i") (PVar "arr")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr")))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))))
(DTypeSig true "first" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "first" ((PVar "arr")) (EApp (EApp (EVar "get") (ELit (LInt 0))) (EVar "arr")))
(DTypeSig true "last" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "last" ((PVar "arr")) (EApp (EApp (EVar "get") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EVar "arr")))
(DTypeSig true "reverse" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "reverse" ((PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EBinOp "-" (EVar "n") (ELit (LInt 1))) (EVar "i"))) (EVar "arr")))))))
(DTypeSig true "sliceClamped" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))))
(DFunDef false "sliceClamped" ((PVar "lo") (PVar "hi") (PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoLet false false (PVar "lo'") (EIf (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EApp (EMethodRef "min") (EVar "lo")) (EVar "n")))) (DoLet false false (PVar "hi'") (EIf (EBinOp "<" (EVar "hi") (EVar "lo'")) (EVar "lo'") (EApp (EApp (EMethodRef "min") (EVar "hi")) (EVar "n")))) (DoLet false false (PVar "m") (EBinOp "-" (EVar "hi'") (EVar "lo'"))) (DoExpr (EIf (EBinOp "<=" (EVar "m") (ELit (LInt 0))) (EArrayLit) (EBlock (DoLet false false (PVar "out") (EApp (EApp (EVar "arrayMake") (EVar "m")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "lo'")) (EVar "arr")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "arr")) (EVar "lo'")) (EVar "out")) (ELit (LInt 0))) (EVar "m"))) (DoExpr (EVar "out")))))))
(DTypeSig true "take" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a")))))
(DFunDef false "take" ((PVar "n") (PVar "arr")) (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 0))) (EVar "n")) (EVar "arr")))
(DTypeSig true "drop" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a")))))
(DFunDef false "drop" ((PVar "n") (PVar "arr")) (EApp (EApp (EApp (EVar "sliceClamped") (EVar "n")) (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "arr")))
(DTypeSig true "concat" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Array") (TyVar "a"))) (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "concat" ((PVar "arrs")) (EBlock (DoLet false false (PVar "outer") (EApp (EVar "arrayLength") (EVar "arrs"))) (DoLet false false (PVar "total") (EApp (EApp (EApp (EApp (EVar "concatTotal") (EVar "arrs")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "outer"))) (DoExpr (EIf (EBinOp "<=" (EVar "total") (ELit (LInt 0))) (EArrayLit) (EBlock (DoLet false false (PVar "out") (EApp (EApp (EVar "arrayMake") (EVar "total")) (EApp (EApp (EApp (EApp (EVar "concatLookup") (EVar "arrs")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "outer")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "concatBlitAll") (EVar "arrs")) (EVar "out")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "outer"))))))))
(DTypeSig false "concatBlitAll" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Array") (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyVar "a"))))))))
(DFunDef false "concatBlitAll" ((PVar "arrs") (PVar "out") (PVar "k") (PVar "dstOff") (PVar "outer")) (EIf (EBinOp ">=" (EVar "k") (EVar "outer")) (EVar "out") (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arrs"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "inner"))) (DoExpr (EIf (EBinOp "<=" (EVar "len") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EVar "concatBlitAll") (EVar "arrs")) (EVar "out")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "dstOff")) (EVar "outer")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "inner")) (ELit (LInt 0))) (EVar "out")) (EVar "dstOff")) (EVar "len"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "concatBlitAll") (EVar "arrs")) (EVar "out")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EBinOp "+" (EVar "dstOff") (EVar "len"))) (EVar "outer")))))))))
(DTypeSig false "concatTotal" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Array") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "concatTotal" ((PVar "arrs") (PVar "i") (PVar "acc") (PVar "outer")) (EIf (EBinOp ">=" (EVar "i") (EVar "outer")) (EVar "acc") (EApp (EApp (EApp (EApp (EVar "concatTotal") (EVar "arrs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (EApp (EVar "arrayLength") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arrs"))))) (EVar "outer"))))
(DTypeSig false "concatLookup" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Array") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a"))))))
(DFunDef false "concatLookup" ((PVar "arrs") (PVar "target") (PVar "k") (PVar "outer")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arrs"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "inner"))) (DoExpr (EIf (EBinOp "<" (EVar "target") (EVar "len")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "target")) (EVar "inner")) (EApp (EApp (EApp (EApp (EVar "concatLookup") (EVar "arrs")) (EBinOp "-" (EVar "target") (EVar "len"))) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "outer"))))))
(DTypeSig true "zip" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "b")) (TyApp (TyCon "Array") (TyTuple (TyVar "a") (TyVar "b"))))))
(DFunDef false "zip" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "n") (EApp (EApp (EMethodRef "min") (EApp (EVar "arrayLength") (EVar "a"))) (EApp (EVar "arrayLength") (EVar "b")))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (ETuple (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "b"))))))))
(DTypeSig true "zipWith" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "c")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "b")) (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "c")))))))
(DFunDef false "zipWith" ((PVar "f") (PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "n") (EApp (EApp (EMethodRef "min") (EApp (EVar "arrayLength") (EVar "a"))) (EApp (EVar "arrayLength") (EVar "b")))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "b"))))))))
(DTypeSig true "unzip" (TyFun (TyApp (TyCon "Array") (TyTuple (TyVar "a") (TyVar "b"))) (TyTuple (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "b")))))
(DFunDef false "unzip" ((PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (ETuple (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))) (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EVar "snd") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))))))))
(DImpl true "Filterable" ((TyCon "Array")) () ((im "filter" ((PVar "p") (PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EArrayLit) (EBlock (DoLet false false (PVar "buf") (EApp (EApp (EVar "arrayMake") (EVar "n")) (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EVar "filterFinish") (EVar "buf")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "filterGo") (EVar "p")) (EVar "arr")) (EVar "buf")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "n"))) (EVar "n")))))))) (im "filterMap" ((PVar "f") (PVar "arr")) (EApp (EApp (EApp (EApp (EVar "filterMapFrom") (EVar "f")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))))
(DTypeSig false "filterGo" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Int")))))))))
(DFunDef false "filterGo" ((PVar "p") (PVar "arr") (PVar "buf") (PVar "i") (PVar "k") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "k") (EBlock (DoLet false false (PVar "x") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (DoExpr (EIf (EApp (EVar "p") (EVar "x")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "k")) (EVar "x")) (EVar "buf"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "filterGo") (EVar "p")) (EVar "arr")) (EVar "buf")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "n")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "filterGo") (EVar "p")) (EVar "arr")) (EVar "buf")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "k")) (EVar "n")))))))
(DTypeSig false "filterFinish" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyVar "a"))))))
(DFunDef false "filterFinish" ((PVar "buf") (PVar "k") (PVar "n")) (EIf (EBinOp "<=" (EVar "k") (ELit (LInt 0))) (EArrayLit) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EVar "buf") (EBlock (DoLet false false (PVar "out") (EApp (EApp (EVar "arrayMake") (EVar "k")) (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "buf")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "buf")) (ELit (LInt 0))) (EVar "out")) (ELit (LInt 0))) (EVar "k"))) (DoExpr (EVar "out"))))))
(DTypeSig false "filterMapFrom" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "b")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "b"))))))))
(DFunDef false "filterMapFrom" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EArrayLit) (EMatch (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "filterMapFrom") (EVar "f")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (arm (PCon "Some" (PVar "y")) () (EBlock (DoLet false false (PVar "buf") (EApp (EApp (EVar "arrayMake") (EVar "n")) (EVar "y"))) (DoExpr (EApp (EApp (EApp (EVar "filterFinish") (EVar "buf")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "filterMapGo") (EVar "f")) (EVar "arr")) (EVar "buf")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (ELit (LInt 1)))) (EVar "n"))))))))
(DTypeSig false "filterMapGo" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "b")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "b")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Int")))))))))
(DFunDef false "filterMapGo" ((PVar "f") (PVar "arr") (PVar "buf") (PVar "i") (PVar "n") (PVar "k")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "k") (EMatch (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (arm (PCon "Some" (PVar "y")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "k")) (EVar "y")) (EVar "buf"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "filterMapGo") (EVar "f")) (EVar "arr")) (EVar "buf")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "+" (EVar "k") (ELit (LInt 1))))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "filterMapGo") (EVar "f")) (EVar "arr")) (EVar "buf")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "k"))))))
(DTypeSig true "setInPlace" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "setInPlace" ((PVar "i") (PVar "x") (PVar "arr")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr")))) (EApp (EVar "indexErrorAt") (EVar "i")) (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "x")) (EVar "arr"))))
(DTypeSig true "swap" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "swap" ((PVar "i") (PVar "j") (PVar "arr")) (EBlock (DoLet false false (PVar "xi") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (DoLet false false (PVar "xj") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "xj")) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "j")) (EVar "xi")) (EVar "arr")))))
(DTypeSig true "fill" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "fill" ((PVar "x") (PVar "arr")) (EApp (EApp (EVar "arrayFill") (EVar "x")) (EVar "arr")))
(DTypeSig true "blit" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit")))))))
(DFunDef false "blit" ((PVar "src") (PVar "srcOff") (PVar "dst") (PVar "dstOff") (PVar "len")) (EIf (EBinOp "<" (EVar "len") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "Array.blit: negative length"))) (EIf (EBinOp "<" (EVar "srcOff") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "Array.blit: negative srcOff"))) (EIf (EBinOp "<" (EVar "dstOff") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "Array.blit: negative dstOff"))) (EIf (EBinOp ">" (EVar "len") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "src")) (EVar "srcOff"))) (EApp (EVar "panic") (ELit (LString "Array.blit: source out of bounds"))) (EIf (EBinOp ">" (EVar "len") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "dst")) (EVar "dstOff"))) (EApp (EVar "panic") (ELit (LString "Array.blit: destination out of bounds"))) (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "src")) (EVar "srcOff")) (EVar "dst")) (EVar "dstOff")) (EVar "len"))))))))
(DTypeSig true "sortInPlaceBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyCon "Unit")))))
(DFunDef false "sortInPlaceBy" ((PVar "cmp") (PVar "arr")) (EBlock (DoLet false false (PVar "sorted") (EApp (EApp (EVar "sortBy") (EVar "cmp")) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "sorted")) (ELit (LInt 0))) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))))
(DTypeSig true "sortInPlace" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "sortInPlace" ((PVar "arr")) (EApp (EApp (EVar "sortInPlaceBy") (EMethodRef "compare")) (EVar "arr")))
(DTypeSig true "sortBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "a"))))))
(DFunDef false "sortBy" ((PVar "cmp") (PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 1))) (EApp (EVar "arrayCopy") (EVar "arr")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "arrayCopy") (EVar "arr"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "sortRuns") (EVar "cmp")) (EVar "src")) (EVar "n")) (ELit (LInt 8))) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "mergePasses") (EVar "cmp")) (EVar "src")) (EApp (EApp (EVar "arrayMake") (EVar "n")) (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "arr")))) (EVar "n")) (ELit (LInt 8)))))))))
(DTypeSig true "sort" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a")))))
(DFunDef false "sort" ((PVar "arr")) (EApp (EApp (EVar "sortBy") (EMethodRef "compare")) (EVar "arr")))
(DTypeSig true "sortOn" (TyConstrained ((cstr "Ord" (TyVar "b"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "a")))))))
(DFunDef false "sortOn" ((PVar "key") (PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoLet false false (PVar "keys") (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EVar "key") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))))) (DoLet false false (PVar "order") (EApp (EApp (EVar "sortBy") (ELam ((PVar "i") (PVar "j")) (EApp (EApp (EMethodRef "compare") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "keys"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "keys"))))) (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EVar "i"))))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "order"))) (EVar "arr")))))))
(DTypeSig false "sortRuns" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit"))))))))
(DFunDef false "sortRuns" ((PVar "cmp") (PVar "a") (PVar "n") (PVar "w") (PVar "lo")) (EIf (EBinOp ">=" (EVar "lo") (EVar "n")) (ELit LUnit) (EBlock (DoLet false false (PVar "hi") (EApp (EApp (EMethodRef "min") (EBinOp "+" (EVar "lo") (EVar "w"))) (EVar "n"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "insertionRun") (EVar "cmp")) (EVar "a")) (EVar "lo")) (EVar "hi")) (EBinOp "+" (EVar "lo") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "sortRuns") (EVar "cmp")) (EVar "a")) (EVar "n")) (EVar "w")) (EVar "hi"))))))
(DTypeSig false "insertionRun" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit"))))))))
(DFunDef false "insertionRun" ((PVar "cmp") (PVar "a") (PVar "lo") (PVar "hi") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "hi")) (ELit LUnit) (EBlock (DoLet false false (PVar "x") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "insertionShift") (EVar "cmp")) (EVar "a")) (EVar "lo")) (EVar "i")) (EVar "x"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "insertionRun") (EVar "cmp")) (EVar "a")) (EVar "lo")) (EVar "hi")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig false "insertionShift" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Unit"))))))))
(DFunDef false "insertionShift" ((PVar "cmp") (PVar "a") (PVar "lo") (PVar "j") (PVar "x")) (EIf (EBinOp "<=" (EVar "j") (EVar "lo")) (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "j")) (EVar "x")) (EVar "a")) (EIf (EApp (EApp (EApp (EVar "isNotGt") (EVar "cmp")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "j") (ELit (LInt 1)))) (EVar "a"))) (EVar "x")) (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "j")) (EVar "x")) (EVar "a")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "j")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "j") (ELit (LInt 1)))) (EVar "a"))) (EVar "a"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "insertionShift") (EVar "cmp")) (EVar "a")) (EVar "lo")) (EBinOp "-" (EVar "j") (ELit (LInt 1)))) (EVar "x")))))))
(DTypeSig false "mergePasses" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "a")))))))))
(DFunDef false "mergePasses" ((PVar "cmp") (PVar "src") (PVar "dst") (PVar "n") (PVar "width")) (EIf (EBinOp ">=" (EVar "width") (EVar "n")) (EVar "src") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeRuns") (EVar "cmp")) (EVar "src")) (EVar "dst")) (EVar "n")) (EVar "width")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "mergePasses") (EVar "cmp")) (EVar "dst")) (EVar "src")) (EVar "n")) (EBinOp "*" (EVar "width") (ELit (LInt 2))))))))
(DTypeSig false "mergeRuns" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit")))))))))
(DFunDef false "mergeRuns" ((PVar "cmp") (PVar "src") (PVar "dst") (PVar "n") (PVar "width") (PVar "lo")) (EIf (EBinOp ">=" (EVar "lo") (EVar "n")) (ELit LUnit) (EBlock (DoLet false false (PVar "mid") (EApp (EApp (EMethodRef "min") (EBinOp "+" (EVar "lo") (EVar "width"))) (EVar "n"))) (DoLet false false (PVar "hi") (EApp (EApp (EMethodRef "min") (EBinOp "+" (EBinOp "+" (EVar "lo") (EVar "width")) (EVar "width"))) (EVar "n"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergePair") (EVar "cmp")) (EVar "src")) (EVar "dst")) (EVar "lo")) (EVar "mid")) (EVar "hi"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeRuns") (EVar "cmp")) (EVar "src")) (EVar "dst")) (EVar "n")) (EVar "width")) (EVar "hi"))))))
(DTypeSig false "mergePair" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit")))))))))
(DFunDef false "mergePair" ((PVar "cmp") (PVar "src") (PVar "dst") (PVar "lo") (PVar "mid") (PVar "hi")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "mid") (EVar "hi")) (EApp (EApp (EApp (EVar "isNotGt") (EVar "cmp")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "mid") (ELit (LInt 1)))) (EVar "src"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "mid")) (EVar "src")))) (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "src")) (EVar "lo")) (EVar "dst")) (EVar "lo")) (EBinOp "-" (EVar "hi") (EVar "lo"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeRun") (EVar "cmp")) (EVar "src")) (EVar "dst")) (EVar "lo")) (EVar "mid")) (EVar "mid")) (EVar "hi")) (EVar "lo"))))
(DTypeSig false "isNotGt" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))))))
(DFunDef false "isNotGt" ((PVar "cmp") (PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "cmp") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True"))))
(DTypeSig false "mergeRun" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit")))))))))))
(DFunDef false "mergeRun" ((PVar "cmp") (PVar "src") (PVar "dst") (PVar "i") (PVar "iEnd") (PVar "j") (PVar "jEnd") (PVar "k")) (EIf (EBinOp ">=" (EVar "i") (EVar "iEnd")) (EApp (EApp (EApp (EApp (EApp (EVar "copyRun") (EVar "src")) (EVar "dst")) (EVar "j")) (EVar "jEnd")) (EVar "k")) (EIf (EBinOp ">=" (EVar "j") (EVar "jEnd")) (EApp (EApp (EApp (EApp (EApp (EVar "copyRun") (EVar "src")) (EVar "dst")) (EVar "i")) (EVar "iEnd")) (EVar "k")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeStep") (EVar "cmp")) (EVar "src")) (EVar "dst")) (EVar "i")) (EVar "iEnd")) (EVar "j")) (EVar "jEnd")) (EVar "k")))))
(DTypeSig false "mergeStep" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit")))))))))))
(DFunDef false "mergeStep" ((PVar "cmp") (PVar "src") (PVar "dst") (PVar "i") (PVar "iEnd") (PVar "j") (PVar "jEnd") (PVar "k")) (EMatch (EApp (EApp (EVar "cmp") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "src"))) (arm (PCon "Gt") () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "k")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "src"))) (EVar "dst"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeRun") (EVar "cmp")) (EVar "src")) (EVar "dst")) (EVar "i")) (EVar "iEnd")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EVar "jEnd")) (EBinOp "+" (EVar "k") (ELit (LInt 1))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "k")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src"))) (EVar "dst"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeRun") (EVar "cmp")) (EVar "src")) (EVar "dst")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "iEnd")) (EVar "j")) (EVar "jEnd")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))))))))
(DTypeSig false "copyRun" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit")))))))
(DFunDef false "copyRun" ((PVar "src") (PVar "dst") (PVar "i") (PVar "iEnd") (PVar "k")) (EIf (EBinOp ">=" (EVar "i") (EVar "iEnd")) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "k")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src"))) (EVar "dst"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "copyRun") (EVar "src")) (EVar "dst")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "iEnd")) (EBinOp "+" (EVar "k") (ELit (LInt 1))))))))
(DTypeSig true "find" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "a"))))))
(DFunDef false "find" ((PVar "pred") (PVar "arr")) (EApp (EApp (EApp (EApp (EVar "findGo") (EVar "pred")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "findGo" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "a"))))))))
(DFunDef false "findGo" ((PVar "pred") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EApp (EVar "pred") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EApp (EApp (EVar "findGo") (EVar "pred")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig true "findIndex" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "findIndex" ((PVar "pred") (PVar "arr")) (EApp (EApp (EApp (EApp (EVar "findIndexGo") (EVar "pred")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "findIndexGo" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "findIndexGo" ((PVar "pred") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EApp (EVar "pred") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EVar "Some") (EVar "i")) (EApp (EApp (EApp (EApp (EVar "findIndexGo") (EVar "pred")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig true "foldWithIndex" (TyFun (TyFun (TyVar "b") (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldWithIndex" ((PVar "f") (PVar "z") (PVar "arr")) (EApp (EApp (EApp (EApp (EApp (EVar "foldWithIndexGo") (EVar "f")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "z")))
(DTypeSig false "foldWithIndexGo" (TyFun (TyFun (TyVar "b") (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b"))))))))
(DFunDef false "foldWithIndexGo" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EApp (EApp (EApp (EApp (EApp (EVar "foldWithIndexGo") (EVar "f")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EApp (EApp (EVar "f") (EVar "acc")) (EVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))))
(DTypeSig true "forEachWithIndex" (TyFun (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Unit")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyCon "Unit")))))
(DFunDef false "forEachWithIndex" ((PVar "f") (PVar "arr")) (EApp (EApp (EApp (EApp (EVar "forEachWithIndexGo") (EVar "f")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "forEachWithIndexGo" (TyFun (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Unit")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit")))))))
(DFunDef false "forEachWithIndexGo" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EApp (EVar "f") (EVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "forEachWithIndexGo") (EVar "f")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))))))
(DTypeSig true "mapWithIndex" (TyFun (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "b"))))))
(DFunDef false "mapWithIndex" ((PVar "f") (PVar "arr")) (EApp (EApp (EVar "arrayMakeWith") (EApp (EVar "arrayLength") (EVar "arr"))) (ELam ((PVar "i")) (EApp (EApp (EVar "f") (EVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))))
(DTypeSig false "isSortedArr" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "isSortedArr" ((PVar "arr")) (EApp (EApp (EApp (EDictApp "isSortedArrGo") (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "isSortedArrGo" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "isSortedArrGo" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "True") (EIf (EApp (EApp (EMethodRef "lte") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EApp (EDictApp "isSortedArrGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DProp false "sortBy ascending and length-preserving" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "sorted") (EApp (EApp (EVar "sortBy") (EMethodRef "compare")) (EVar "arr"))) (DoExpr (EBinOp "&&" (EApp (EDictApp "isSortedArr") (EVar "sorted")) (EBinOp "==" (EApp (EMethodRef "length") (EVar "sorted")) (EApp (EMethodRef "length") (EVar "arr")))))))
(DProp false "sortBy idempotent" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "sorted") (EApp (EApp (EVar "sortBy") (EMethodRef "compare")) (EVar "arr"))) (DoExpr (EApp (EApp (EMethodRef "eq") (EVar "sorted")) (EApp (EApp (EVar "sortBy") (EMethodRef "compare")) (EVar "sorted"))))))
(DProp false "sortBy stable: equal keys preserve original order" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EApp (EApp (EMethodRef "map") (ELam ((PVar "x")) (ETuple (ELit (LInt 0)) (EVar "x")))) (EVar "xs")))) (DoLet false false (PVar "sorted") (EApp (EApp (EVar "sortBy") (ELam ((PTuple (PVar "k1") PWild) (PTuple (PVar "k2") PWild)) (EApp (EApp (EMethodRef "compare") (EVar "k1")) (EVar "k2")))) (EVar "arr"))) (DoExpr (EApp (EApp (EMethodRef "eq") (EApp (EMethodRef "toList") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "sorted")))) (EVar "xs")))))
(DProp false "makeWith length" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "n'") (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n"))) (DoExpr (EBinOp "==" (EApp (EMethodRef "length") (EApp (EApp (EVar "makeWith") (EVar "n'")) (ELam ((PVar "i")) (EVar "i")))) (EVar "n'")))))
(DProp false "makeWith element at index 0" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "n'") (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ELit (LInt 1)) (EVar "n"))) (DoExpr (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EApp (EVar "makeWith") (EVar "n'")) (ELam ((PVar "i")) (EBinOp "+" (EBinOp "*" (EVar "i") (ELit (LInt 3))) (ELit (LInt 7)))))) (ELit (LInt 7))))))
(DProp false "foldWithIndex matches fold over zip with range" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "viaIndex") (EApp (EApp (EApp (EVar "foldWithIndex") (ELam ((PVar "acc") (PVar "i") (PVar "x")) (EBinOp "::" (ETuple (EVar "i") (EVar "x")) (EVar "acc")))) (EListLit)) (EVar "arr"))) (DoLet false false (PVar "viaZip") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "pair")) (EBinOp "::" (EVar "pair") (EVar "acc")))) (EListLit)) (EApp (EApp (EVar "zip") (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EMethodRef "length") (EVar "arr")))) (EVar "arr")))) (DoExpr (EApp (EApp (EMethodRef "eq") (EVar "viaIndex")) (EVar "viaZip")))))
(DProp false "forEachWithIndex visits every index once, in order, matching zip with range" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "seen") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "forEachWithIndex") (ELam ((PVar "i") (PVar "x")) (EApp (EApp (EVar "setRef") (EVar "seen")) (EBinOp "::" (ETuple (EVar "i") (EVar "x")) (EUnOp "!" (EVar "seen")))))) (EVar "arr"))) (DoLet false false (PVar "viaZip") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "pair")) (EBinOp "::" (EVar "pair") (EVar "acc")))) (EListLit)) (EApp (EApp (EVar "zip") (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EMethodRef "length") (EVar "arr")))) (EVar "arr")))) (DoExpr (EApp (EApp (EMethodRef "eq") (EUnOp "!" (EVar "seen"))) (EVar "viaZip")))))
(DProp false "mapWithIndex with an index-ignoring callback is map" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "mapWithIndex") (ELam (PWild (PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 1))))) (EVar "arr"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 1))))) (EVar "arr"))))))
(DProp false "mapWithIndex hands the callback 0..n-1 in order" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "mapWithIndex") (ELam ((PVar "i") PWild) (EVar "i"))) (EVar "arr"))) (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EMethodRef "length") (EVar "arr")))))))
(DProp false "mapWithIndex agrees with zipWith over range" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "mapWithIndex") (ELam ((PVar "i") (PVar "x")) (EBinOp "+" (EBinOp "*" (EVar "i") (ELit (LInt 10))) (EVar "x")))) (EVar "arr"))) (EApp (EApp (EApp (EVar "zipWith") (ELam ((PVar "i") (PVar "x")) (EBinOp "+" (EBinOp "*" (EVar "i") (ELit (LInt 10))) (EVar "x")))) (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EMethodRef "length") (EVar "arr")))) (EVar "arr"))))))
(DTypeSig false "isStableKeyedArr" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "isStableKeyedArr" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EVar "True") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (DoLet false false (PVar "b") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EApp (EVar "fst") (EVar "a")) (EApp (EVar "fst") (EVar "b"))) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EVar "a")) (EApp (EVar "fst") (EVar "b"))) (EBinOp "<" (EApp (EVar "snd") (EVar "a")) (EApp (EVar "snd") (EVar "b"))))) (EApp (EApp (EVar "isStableKeyedArr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "False")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DProp false "sortBy is stable on keys with many duplicates" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "tagged") (EApp (EApp (EVar "zip") (EApp (EApp (EMethodRef "map") (ELam ((PVar "x")) (EBinOp "%" (EVar "x") (ELit (LInt 3))))) (EApp (EVar "fromList") (EVar "xs")))) (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EMethodRef "length") (EVar "xs"))))) (DoExpr (EApp (EApp (EVar "isStableKeyedArr") (EApp (EApp (EVar "sortBy") (ELam ((PTuple (PVar "k1") PWild) (PTuple (PVar "k2") PWild)) (EApp (EApp (EMethodRef "compare") (EVar "k1")) (EVar "k2")))) (EVar "tagged"))) (ELit (LInt 0))))))
(DProp false "sort of already-sorted, reversed, and duplicate-heavy input" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "sorted") (EApp (EDictApp "sort") (EVar "arr"))) (DoLet false false (PVar "dups") (EApp (EApp (EMethodRef "map") (ELam ((PVar "x")) (EBinOp "%" (EVar "x") (ELit (LInt 4))))) (EVar "arr"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EDictApp "sort") (EVar "sorted"))) (EVar "sorted")) (EApp (EApp (EMethodRef "eq") (EApp (EDictApp "sort") (EApp (EVar "reverse") (EVar "arr")))) (EVar "sorted"))) (EApp (EDictApp "isSortedArr") (EApp (EDictApp "sort") (EVar "dups")))) (EBinOp "==" (EApp (EMethodRef "length") (EApp (EDictApp "sort") (EVar "dups"))) (EApp (EMethodRef "length") (EVar "arr")))))))
(DProp false "sortOn agrees with sortBy on the same key" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EMethodRef "eq") (EApp (EApp (EDictApp "sortOn") (ELam ((PVar "x")) (EBinOp "%" (EVar "x") (ELit (LInt 5))))) (EVar "arr"))) (EApp (EApp (EVar "sortBy") (ELam ((PVar "a") (PVar "b")) (EApp (EApp (EMethodRef "compare") (EBinOp "%" (EVar "a") (ELit (LInt 5)))) (EBinOp "%" (EVar "b") (ELit (LInt 5)))))) (EVar "arr"))))))
(DProp false "filter agrees with List filter" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EMethodRef "eq") (EApp (EMethodRef "toList") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "x")) (EBinOp "==" (EBinOp "%" (EVar "x") (ELit (LInt 3))) (ELit (LInt 0))))) (EVar "arr")))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "x")) (EBinOp "==" (EBinOp "%" (EVar "x") (ELit (LInt 3))) (ELit (LInt 0))))) (EVar "xs"))))))
(DProp false "filterMap agrees with List filterMap" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "f") (ELam ((PVar "x")) (EIf (EBinOp "==" (EBinOp "%" (EVar "x") (ELit (LInt 3))) (ELit (LInt 0))) (EApp (EVar "Some") (EBinOp "*" (EVar "x") (ELit (LInt 2)))) (EVar "None")))) (DoExpr (EApp (EApp (EMethodRef "eq") (EApp (EMethodRef "toList") (EApp (EApp (EMethodRef "filterMap") (EVar "f")) (EVar "arr")))) (EApp (EApp (EMethodRef "filterMap") (EVar "f")) (EVar "xs"))))))
(DProp false "take, drop and sliceClamped agree with an index filter" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "lo" (TyCon "Int")) (pp "hi" (TyCon "Int"))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "pairs") (EApp (EMethodRef "toList") (EApp (EApp (EVar "zip") (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EMethodRef "length") (EVar "arr")))) (EVar "arr")))) (DoLet false false (PVar "inRange") (ELam ((PVar "p")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "fst") (EVar "p")) (EVar "lo")) (EBinOp "<" (EApp (EVar "fst") (EVar "p")) (EVar "hi"))))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EMethodRef "toList") (EApp (EApp (EApp (EVar "sliceClamped") (EVar "lo")) (EVar "hi")) (EVar "arr")))) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EApp (EMethodRef "filter") (EVar "inRange")) (EVar "pairs")))) (EApp (EApp (EMethodRef "eq") (EApp (EMethodRef "toList") (EApp (EApp (EVar "take") (EVar "lo")) (EVar "arr")))) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "p")) (EBinOp "<" (EApp (EVar "fst") (EVar "p")) (EVar "lo")))) (EVar "pairs"))))) (EApp (EApp (EMethodRef "eq") (EApp (EMethodRef "toList") (EApp (EApp (EVar "drop") (EVar "lo")) (EVar "arr")))) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "p")) (EBinOp ">=" (EApp (EVar "fst") (EVar "p")) (EVar "lo")))) (EVar "pairs"))))))))
