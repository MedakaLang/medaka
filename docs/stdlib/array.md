# array

Operations on `Array a`.

An array is a fixed-size sequence with `O(1)` indexing, written
`[|1, 2, 3|]`. The functions here return new arrays, except those whose
names say they work in place (`setInPlace`, `swap`, `fill`, `blit`,
`sortInPlace`), which change the array they are given and return `Unit`.
For an array that grows, see `vector`.

`length`, `isEmpty`, `toList`, `map`, `filter`, `fold`, `elem`, `sum`,
`maximum`, and the other `Foldable` and `Mappable` operations work on
arrays through the instances in this module and the prelude. `arr[i]`
panics on an out-of-range index; `get` is the `Option`-returning form.

## Construction

### `singleton`

```
singleton : a -> Array a
```

An array holding one element.

```medaka
> toList (singleton 5)
[5]
```

### `make`

```
make : Int -> a -> Array a
```

An array of `n` copies of `x`.

```medaka
> toList (make 3 0)
[0, 0, 0]
```

### `makeWith`

```
makeWith : Int -> (Int -> <e> a) -> <e> Array a
```

An array of length `n` whose element at each index `i` is `f i`.

Empty when `n <= 0`.

```medaka
> toList (makeWith 3 (i => i * 2))
[0, 2, 4]
```

### `fromList`

```
fromList : List a -> Array a
```

An array holding the elements of a list, in order.

```medaka
> fromList [1, 2, 3]
[|1, 2, 3|]
```

### `range`

```
range : Int -> Int -> Array Int
```

The integers from `lo` up to, but not including, `hi`.

Empty when `hi <= lo`.

```medaka
> toList (range 0 4)
[0, 1, 2, 3]
```

### `copy`

```
copy : Array a -> Array a
```

A new array with the same elements.

Use it to keep the original before an in-place operation.

```medaka
> copy [|1, 2|]
[|1, 2|]
```

## Reading

### `get`

```
get : Int -> Array a -> Option a
```

The element at index `i`, or `None` when `i` is out of range.

`arr[i]` is the panicking form.

```medaka
> get 0 (fromList [1, 2, 3])
Some 1
> get 5 (fromList [1, 2, 3])
None
```

### `first`

```
first : Array a -> Option a
```

The first element, or `None` when the array is empty.

```medaka
> first (fromList [1, 2, 3])
Some 1
```

### `last`

```
last : Array a -> Option a
```

The last element, or `None` when the array is empty.

```medaka
> last (fromList [1, 2, 3])
Some 3
```

## Transformation

### `reverse`

```
reverse : Array a -> Array a
```

A new array with the elements in reverse order.

```medaka
> toList (reverse (fromList [1, 2, 3]))
[3, 2, 1]
```

### `sliceClamped`

```
sliceClamped : Int -> Int -> Array a -> Array a
```

A new array of the elements at indices `[lo, hi)`.

Indices are clamped to the array, so an out-of-range slice is shorter
rather than a panic. `arr.[lo..hi]` is the panicking form.

```medaka
> toList (sliceClamped 1 3 (fromList [1, 2, 3, 4, 5]))
[2, 3]
```

### `take`

```
take : Int -> Array a -> Array a
```

A new array of the first `n` elements, or of the whole array when it
is shorter.

```medaka
> toList (take 2 (fromList [1, 2, 3, 4]))
[1, 2]
```

### `drop`

```
drop : Int -> Array a -> Array a
```

A new array of everything after the first `n` elements.

```medaka
> toList (drop 2 (fromList [1, 2, 3, 4]))
[3, 4]
```

### `concat`

```
concat : Array (Array a) -> Array a
```

The inner arrays joined into one.

Costs `O(n)` in the total number of elements.

```medaka
> toList (concat (fromList [fromList [1, 2], fromList [3]]))
[1, 2, 3]
```

### `zip`

```
zip : Array a -> Array b -> Array (a, b)
```

The elements of two arrays paired up by position.

The result is as long as the shorter input.

```medaka
> toList (zip (fromList [1, 2, 3]) (fromList ["a", "b"]))
[(1, "a"), (2, "b")]
```

### `zipWith`

```
zipWith : (a -> b -> <e> c) -> Array a -> Array b -> <e> Array c
```

The elements of two arrays combined by position with `f`.

The result is as long as the shorter input.

```medaka
> toList (zipWith (x y => x + y) (fromList [1, 2]) (fromList [10, 20]))
[11, 22]
```

### `unzip`

```
unzip : Array (a, b) -> (Array a, Array b)
```

An array of pairs separated into two arrays. The inverse of `zip`.

```medaka
> let (xs, ys) = unzip (fromList [(1, 2), (3, 4)]) in (toList xs, toList ys)
([1, 3], [2, 4])
```

## Mutation

### `setInPlace`

```
setInPlace : Int -> a -> Array a -> Unit
```

Replaces the element at index `i` with `x`.

Panics when `i` is out of range.

```medaka
> let arr = fromList [1, 2, 3] in let _ = setInPlace 1 9 arr in toList arr
[1, 9, 3]
```

### `swap`

```
swap : Int -> Int -> Array a -> Unit
```

Exchanges the elements at indices `i` and `j`.

Both indices must be in range.

```medaka
> let arr = fromList [1, 2, 3] in let _ = swap 0 2 arr in toList arr
[3, 2, 1]
```

### `fill`

```
fill : a -> Array a -> Unit
```

Replaces every element with `x`.

```medaka
> let arr = fromList [1, 2, 3] in let _ = fill 0 arr in toList arr
[0, 0, 0]
```

### `blit`

```
blit : Array a -> Int -> Array a -> Int -> Int -> Unit
```

Copies `len` elements from `src`, starting at `srcOff`, into `dst`,
starting at `dstOff`.

Panics when any argument is negative or the copy would run past either
array's end.

```medaka
> let dst = make 4 0 in let _ = blit (fromList [1, 2]) 0 dst 1 2 in toList dst
[0, 1, 2, 0]
```

## Sorting

### `sortInPlaceBy`

```
sortInPlaceBy : (a -> a -> <e> Ordering) -> Array a -> <e> Unit
```

Sorts the array in place by `cmp`.

The sort is stable.

```medaka
> let arr = fromList [3, 1, 2] in let _ = sortInPlaceBy compare arr in toList arr
[1, 2, 3]
```

### `sortInPlace`

```
sortInPlace : Ord a => Array a -> Unit
```

Sorts the array in place in ascending order.

The sort is stable.

```medaka
> let arr = fromList [3, 1, 2] in let _ = sortInPlace arr in toList arr
[1, 2, 3]
```

### `sortBy`

```
sortBy : (a -> a -> <e> Ordering) -> Array a -> <e> Array a
```

A new array of the elements sorted by `cmp`.

The sort is stable: elements that compare equal keep their original
order. It costs `O(n log n)`.

```medaka
> toList (sortBy (x y => compare y x) (fromList [3, 1, 2]))
[3, 2, 1]
```

### `sort`

```
sort : Ord a => Array a -> Array a
```

A new array of the elements in ascending order.

The sort is stable.

```medaka
> toList (sort (fromList [3, 1, 4, 1, 5]))
[1, 1, 3, 4, 5]
```

### `sortOn`

```
sortOn : Ord b => (a -> <e> b) -> Array a -> <e> Array a
```

A new array of the elements in ascending order of `key`.

`key` is computed once per element, so it may be expensive. The sort is
stable.

```medaka
> toList (sortOn (x => 0 - x) (fromList [1, 3, 2]))
[3, 2, 1]
```

## Searching

### `find`

```
find : (a -> <e> Bool) -> Array a -> <e> Option a
```

The first element satisfying `pred`, or `None`.

```medaka
> find (x => x > 1) (fromList [1, 2, 3])
Some 2
```

### `findIndex`

```
findIndex : (a -> <e> Bool) -> Array a -> <e> Option Int
```

The index of the first element satisfying `pred`, or `None`.

```medaka
> findIndex (x => x > 2) (fromList [1, 2, 3])
Some 2
```

## Indexed iteration

### `foldWithIndex`

```
foldWithIndex : (b -> Int -> a -> <e> b) -> b -> Array a -> <e> b
```

A left fold whose step also receives each element's index.

```medaka
> foldWithIndex (acc i x => acc + i * x) 0 (fromList [10, 20, 30])
80
```

### `forEachWithIndex`

```
forEachWithIndex : (Int -> a -> <e> Unit) -> Array a -> <e> Unit
```

Runs `f` on each index and element in order, for its effect.

```medaka
> let acc = Ref [] in let _ = forEachWithIndex (i x => acc := (i, x) :: !acc) (fromList [7, 8, 9]) in !acc
[(2, 9), (1, 8), (0, 7)]
```

### `mapWithIndex`

```
mapWithIndex : (Int -> a -> <e> b) -> Array a -> <e> Array b
```

Like `map`, with `f` also receiving each element's index.

```medaka
> toList (mapWithIndex (i x => i * x) (fromList [1, 2, 3]))
[0, 2, 6]
```

## Instances

- `Array`: [`Filterable`](#filterable-array), `Mappable`, `Foldable`, `Semigroup`, [`Monoid`](#monoid-array-a), [`Debug`](#debug-array-a), `Eq`, [`Ord`](#ord-array-a), [`Display`](#display-array-a), `Hashable`, [`Index`](#index-array-a-int-a), [`IndexMut`](#indexmut-array-a-int-a), [`Slice`](#slice-array-a)

### `Filterable Array`

```
impl Filterable Array
```

`filter` and `filterMap` return a new array of the elements that
survive.

```medaka
> toList (filter isEven (fromList [1, 2, 3, 4]))
[2, 4]
```

### `Monoid (Array a)`

```
impl Monoid (Array a)
```

`empty` is the empty array.

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

