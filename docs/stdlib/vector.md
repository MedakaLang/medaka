# vector

## `Vector`

```
data Vector a
  = Vector (Ref (Array a)) (Ref Int)
```

Instances: [`Index`](#index-vector-a-int-a), [`IndexMut`](#indexmut-vector-a-int-a), [`Foldable`](#foldable-vector), [`Eq`](#eq-vector-a), [`Debug`](#debug-vector-a), [`Display`](#display-vector-a)

## `new`

```
new : Unit -> Vector a
```

A fresh, empty vector (capacity 0; grows on first `push`).  Takes `Unit`,
not a nullary value, so each call allocates its own cells.

## `fromList`

```
fromList : List a -> Vector a
```

Build a vector from a list, preserving order.  Capacity equals the length
(the next `push` triggers a grow).

```medaka
> length (fromList [1, 2, 3])
3
```

## `fromArray`

```
fromArray : Array a -> Vector a
```

Wrap a *copy* of an array as a vector (so later mutation does not disturb
the caller's array).

## `capacity`

```
capacity : Vector a -> Int
```

Capacity of the backing store (`>= length`).  Grows by doubling.

```medaka
> capacity (fromList [1, 2, 3])
3
```

## `get`

```
get : Int -> Vector a -> Option a
```

Element at an index, or `None` when out of the live range `[0, length)`.

```medaka
> get 1 (fromList [10, 20, 30])
Some 20
> get 5 (fromList [10, 20, 30])
None
```

## `first`

```
first : Vector a -> Option a
```

First element, or `None` when empty.

```medaka
> first (fromList [10, 20, 30])
Some 10
```

## `last`

```
last : Vector a -> Option a
```

Last element, or `None` when empty.

```medaka
> last (fromList [10, 20, 30])
Some 30
```

## `toArray`

```
toArray : Vector a -> Array a
```

Snapshot the live range into a fresh fixed-size `Array a`.  (Shown here via
the `arrayLength` kernel primitive — `Array`'s own `Foldable`/`Debug` live in
`array.mdk`, which this module does not import.)

```medaka
> arrayLength (toArray (fromList [1, 2, 3]))
3
```

## `push`

```
push : a -> Vector a -> Unit
```

Append an element, growing (doubling) the backing store when it is full.
Amortized O(1).

## `pop`

```
pop : Vector a -> Option a
```

Remove and return the last element, or `None` when empty.  Keeps capacity
(no shrink).

## `setInPlace`

```
setInPlace : Int -> a -> Vector a -> Unit
```

Overwrite the element at an index.  Panics when out of the live range
`[0, length)` (use `push` to extend).

## `swap`

```
swap : Int -> Int -> Vector a -> Unit
```

Exchange the elements at two indices.  Caller ensures both are in range.

## `clear`

```
clear : Vector a -> Unit
```

Drop all elements (length 0), retaining the allocated capacity.

## `mapInPlace`

```
mapInPlace : (a -> a) -> Vector a -> Unit
```

Apply `f` to every live element in place.

## `insertAt`

```
insertAt : Int -> a -> Vector a -> Unit
```

Insert `x` so that it lands at index `i`, shifting the rest right.
`i <= 0` prepends; `i >= length` appends.  Grows the backing store when
full, like `push`.

```medaka
> let ma = fromList [1, 2, 3] in let _ = insertAt 1 9 ma in toList ma
[1, 9, 2, 3]
> let ma = fromList [1, 2] in let _ = insertAt 7 9 ma in toList ma
[1, 2, 9]
```

## `removeAt`

```
removeAt : Int -> Vector a -> Unit
```

Drop the element at index `i`.  Out of range leaves the vector unchanged.

```medaka
> let ma = fromList [1, 2, 3] in let _ = removeAt 1 ma in toList ma
[1, 3]
> let ma = fromList [1, 2] in let _ = removeAt 7 ma in toList ma
[1, 2]
```

## `sortBy`

```
sortBy : (a -> a -> <e> Ordering) -> Vector a -> <e> Unit
```

Sort the live range in place with the supplied comparison.  Stable --
equal elements keep their original relative order -- because `list.sortBy`,
which does the work, is.

```medaka
> let ma = fromList [3, 1, 4, 1, 5] in let _ = sortBy compare ma in toList ma
[1, 1, 3, 4, 5]
```

## `sort`

```
sort : Ord a => Vector a -> Unit
```

Sort the live range in place by the `Ord` instance.

```medaka
> let ma = fromList [3, 1, 2] in let _ = sort ma in toList ma
[1, 2, 3]
```

## Instances

### `Index (Vector a) Int a`

```
impl Index (Vector a) Int a
```

`index ma i` reads `ma`'s element at `i` (`ma[i]` sugar dispatches here),
over the live range `[0, length)`.  O(1).  Raises the coded `indexError`
(E-INDEX-OOB) when `i` is out of range -- use `get` for a safe
`Option`-returning read instead.

### `IndexMut (Vector a) Int a`

```
impl IndexMut (Vector a) Int a
```

`setIndex ma i v` writes `v` at `ma`'s index `i`, in place, over the live
range `[0, length)`, and returns `ma`.  O(1).  Raises the coded
`indexError` (E-INDEX-OOB) when `i` is out of range.

### `Foldable Vector`

```
impl Foldable Vector
```

Folds over the live range (in order), so `toList`/`length`/`sum`/`elem`/
`any`/… all work on a `Vector`.

```medaka
> sum (fromList [1, 2, 3, 4])
10
> length (fromList [9, 8, 7])
3
```

### `Eq (Vector a)`

```
impl Eq (Vector a) requires Eq a
```

Element-wise equality over the live ranges (capacity is irrelevant).

```medaka
> eq (fromList [1, 2, 3]) (fromList [1, 2, 3])
True
```

### `Debug (Vector a)`

```
impl Debug (Vector a) requires Debug a
```

Rendered as `fromList [a, …]` over the live range.

```medaka
> debug (fromList [1, 2, 3]) == "fromList [1, 2, 3]"
True
```

### `Display (Vector a)`

```
impl Display (Vector a) requires Display a
```

Same `fromList [...]` shape as `Debug`, over the live range, with the
elements rendered by THEIR `Display` (so strings lose their quotes).
`Vector` was the one container in the surface that `println` could not
take (sheet row A-4).

```medaka
> display (fromList [1, 2, 3]) == "fromList [1, 2, 3]"
True
```

