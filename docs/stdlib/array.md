# array

## `singleton`

```
singleton : a -> Array a
```

A one-element array.

```medaka
> toList (singleton 5)
[5]
```

## `make`

```
make : Int -> a -> Array a
```

`make n x` — a fresh array of `n` copies of `x`.

```medaka
> toList (make 3 0)
[0, 0, 0]
```

## `makeWith`

```
makeWith : Int -> (Int -> <e> a) -> <e> Array a
```

`makeWith n f` — a fresh array whose element `i` is `f i`.

```medaka
> toList (makeWith 3 (i => i * 2))
[0, 2, 4]
> length (makeWith 0 (i => i))
0
```

## `fromList`

```
fromList : List a -> Array a
```

Build an array from a list, preserving order.

## `range`

```
range : Int -> Int -> Array Int
```

Half-open `[lo, hi)`.  Empty when `hi <= lo`.

```medaka
> toList (range 0 4)
[0, 1, 2, 3]
```

## `copy`

```
copy : Array a -> Array a
```

Fresh copy with the same contents.  Useful before in-place mutation
when you want to preserve the original.

## `get`

```
get : Int -> Array a -> Option a
```

Bounds-checked indexing.  `arr[i]` (which panics on OOB) is the fast
path; `get` is the safe one.

```medaka
> get 0 (fromList [1, 2, 3])
Some 1
> get 5 (fromList [1, 2, 3])
None
```

## `first`

```
first : Array a -> Option a
```

First element, or `None` when empty.

```medaka
> first (fromList [1, 2, 3])
Some 1
```

## `last`

```
last : Array a -> Option a
```

Last element, or `None` when empty.

```medaka
> last (fromList [1, 2, 3])
Some 3
```

## `reverse`

```
reverse : Array a -> Array a
```

Reverse the array into a fresh one.

```medaka
> toList (reverse (fromList [1, 2, 3]))
[3, 2, 1]
```

## `sliceClamped`

```
sliceClamped : Int -> Int -> Array a -> Array a
```

`sliceClamped lo hi arr` — half-open `[lo, hi)`.  Clamps to the array bounds:
a request outside `[0, length arr]` is silently truncated, never panics.
Use `arr.[lo..hi]` (the `Slice` interface) if you want OOB to panic instead.

```medaka
> toList (sliceClamped 1 3 (fromList [1, 2, 3, 4, 5]))
[2, 3]
```

## `take`

```
take : Int -> Array a -> Array a
```

First `n` elements (fewer if the array is shorter).

```medaka
> toList (take 2 (fromList [1, 2, 3, 4]))
[1, 2]
```

## `drop`

```
drop : Int -> Array a -> Array a
```

All but the first `n` elements.

```medaka
> toList (drop 2 (fromList [1, 2, 3, 4]))
[3, 4]
```

## `concat`

```
concat : Array (Array a) -> Array a
```

Flatten one level.  Two passes: sum the inner lengths, then bulk-copy
each inner array into the result with one `arrayBlit` per inner.
O(outer + total).

```medaka
> toList (concat (fromList [fromList [1, 2], fromList [3]]))
[1, 2, 3]
```

## `zip`

```
zip : Array a -> Array b -> Array (a, b)
```

Pair up two arrays element-wise, truncating to the shorter length.

## `zipWith`

```
zipWith : (a -> b -> <e> c) -> Array a -> Array b -> <e> Array c
```

Combine two arrays element-wise with `f`, truncating to the shorter.

```medaka
> toList (zipWith (x y => x + y) (fromList [1, 2]) (fromList [10, 20]))
[11, 22]
```

## `unzip`

```
unzip : Array (a, b) -> (Array a, Array b)
```

Split an array of pairs into two parallel arrays — the inverse of `zip`.

```medaka
> let (xs, ys) = unzip (fromList [(1, 2), (3, 4)]) in (toList xs, toList ys)
([1, 3], [2, 4])
```

## `setInPlace`

```
setInPlace : Int -> a -> Array a -> Unit
```

Bounds-checked write.  Panics on OOB.

## `swap`

```
swap : Int -> Int -> Array a -> Unit
```

Exchange the elements at indices `i` and `j` in place.

## `fill`

```
fill : a -> Array a -> Unit
```

Overwrite every element with `x` in place.

## `blit`

```
blit : Array a -> Int -> Array a -> Int -> Int -> Unit
```

Bounds-checked bulk copy: copies `len` elements from `src` at offset
  `srcOff` into `dst` at offset `dstOff`.  Panics when any argument is
  negative or the copy would exceed either array's bounds.

## `sortInPlaceBy`

```
sortInPlaceBy : (a -> a -> <e> Ordering) -> Array a -> <e> Unit
```

Sort in place using the supplied comparison.

## `sortInPlace`

```
sortInPlace : Ord a => Array a -> Unit
```

Sort in place by the `Ord` instance.

## `sortBy`

```
sortBy : (a -> a -> <e> Ordering) -> Array a -> <e> Array a
```

Sort into a fresh array using the supplied comparison (stable mergesort).

```medaka
> toList (sortBy compare (fromList [3, 1, 4, 1, 5]))
[1, 1, 3, 4, 5]
> toList (sortBy (x y => compare y x) (fromList [3, 1, 2]))
[3, 2, 1]
```

## `sort`

```
sort : Ord a => Array a -> Array a
```

Sort into a fresh array by the `Ord` instance.

```medaka
> toList (sort (fromList [3, 1, 4, 1, 5]))
[1, 1, 3, 4, 5]
```

## `sortOn`

```
sortOn : Ord b => (a -> <e> b) -> Array a -> <e> Array a
```

Sort into a fresh array by a key projection, computing the key once per
element (decorate–sort–undecorate) so an expensive `key` isn't recomputed in
every comparison — matching `List.sortOn`.

```medaka
> toList (sortOn (x => 0 - x) (fromList [1, 3, 2]))
[3, 2, 1]
```

## `find`

```
find : (a -> <e> Bool) -> Array a -> <e> Option a
```

First element satisfying the predicate, or `None`.

## `findIndex`

```
findIndex : (a -> <e> Bool) -> Array a -> <e> Option Int
```

Index of the first element satisfying the predicate, or `None`.

```medaka
> findIndex (x => x > 2) (fromList [1, 2, 3])
Some 2
```

## `foldWithIndex`

```
foldWithIndex : (b -> Int -> a -> <e> b) -> b -> Array a -> <e> b
```

Left-to-right fold, threading the running index alongside each element.

```medaka
> foldWithIndex (acc i x => acc + i * x) 0 (fromList [10, 20, 30])
80
> foldWithIndex (acc i x => (i, x) :: acc) [] (fromList ([] : List Int))
[]
```

## `forEachWithIndex`

```
forEachWithIndex : (Int -> a -> <e> Unit) -> Array a -> <e> Unit
```

Visit every element in order, applying `f` to its index and itself for
the side effect. The bounds-safe replacement for hand-rolled index
recursion over `get`/`arrayGetUnsafe` in effectful loops (e.g. streaming
an array's bytes into a writer).

```medaka
> let acc = Ref [] in let _ = forEachWithIndex (i x => acc := (i, x) :: !acc) (fromList [7, 8, 9]) in !acc
[(2, 9), (1, 8), (0, 7)]
```

## `mapWithIndex`

```
mapWithIndex : (Int -> a -> <e> b) -> Array a -> <e> Array b
```

Map every element together with its 0-based index — the missing member of
the index-callback family (`foldWithIndex`, `forEachWithIndex`), with the
same `(i x)` callback order `list.mapWithIndex` uses.

```medaka
> toList (mapWithIndex (i x => i * x) (fromList [1, 2, 3]))
[0, 2, 6]
> toList (mapWithIndex (i x => i + x) (fromList ([] : List Int)))
[]
```

## Instances

- `Array`: [`Filterable`](#filterable-array), `Mappable`, `Foldable`, `Semigroup`, [`Monoid`](#monoid-array-a), [`Debug`](#debug-array-a), `Eq`, [`Ord`](#ord-array-a), [`Display`](#display-array-a), `Hashable`, [`Index`](#index-array-a-int-a), [`IndexMut`](#indexmut-array-a-int-a), [`Slice`](#slice-array-a)

### `Filterable Array`

```
impl Filterable Array
```

`Filterable Array`.  Only `filterMap` is defined; `filter` comes from
the interface default.  `filterMap` filters via a list intermediate
(tail-recursive, builds reversed then `arrayFromList` after a final
reverse): one O(N) traversal + one O(M) list build + one O(M) array
copy, no mutation so the signature stays pure.

### `Monoid (Array a)`

```
impl Monoid (Array a)
```

`Monoid.empty` for `Array` is the empty array.  `empty` is nullary, so it
dispatches on its annotated *result* type (Phase 103):

```medaka
> length (empty : Array Int)
0
```

### `Debug (Array a)`

```
impl Debug (Array a) requires Debug a
```

Arrays render in their literal syntax, `[|1, 2, 3|]`.

```medaka
> debug [|1, 2, 3|]
"[|1, 2, 3|]"
```

### `Ord (Array a)`

```
impl Ord (Array a) requires Ord a
```

Arrays compare lexicographically, exactly as the lists of their
elements would.

### `Display (Array a)`

```
impl Display (Array a) requires Display a
```

Arrays render in their literal syntax, `[|1, 2, 3|]`, with the elements
unquoted.

```medaka
> display [|1, 2, 3|]
"[|1, 2, 3|]"
```

### `Index (Array a) Int a`

```
impl Index (Array a) Int a
```

`arr[i]` reads the element at `i` in `O(1)`.

Panics with an index error when `i` is out of range; `array.get` is the
`Option`-returning form.

### `IndexMut (Array a) Int a`

```
impl IndexMut (Array a) Int a
```

Writes the element at `i` in place, in `O(1)`.

Panics with an index error when `i` is out of range.

### `Slice (Array a)`

```
impl Slice (Array a)
```

Copies the elements over `[lo, hi)` into a new array, in `O(hi - lo)`.

Panics with a slice error when the range runs outside the array;
`array.sliceClamped` clamps instead.

```medaka
> slice [|10, 20, 30, 40, 50|] 1 3
[|20, 30|]
```

