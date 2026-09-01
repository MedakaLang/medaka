# vector

vector.mdk — a growable array (a dynamic array, `Vec` in Rust, `vector` in
C++, `ArrayList` in Java).

`Array a` (Module 4) is **fixed-size**: O(1) random access, but no `push`/
`pop`.  `Vector a` is the growable counterpart — backed by an
`Array a` with spare capacity, so `push` is amortized O(1) (the backing
doubles when full, like the hash tables in Module 6).  Reach for `Array` when
the length is known up front; reach for `Vector` when you accumulate.

Representation: `Vector backing len` where `!backing` is the backing
array (its `arrayLength` is the *capacity*) and `!len` is the number of
live elements (`0 <= len <= capacity`).  Both are `Ref`s, mutated in place.
Slots `[len, capacity)` are scratch — never read; they hold
whatever value last filled them (the most recent `push`'s element on a grow).

Iteration / instances only ever touch the live range `[0, len)`, so the
scratch tail is invisible.  `empty`/`new` start at capacity 0 and allocate on
first `push`, using the pushed element as the fill — so no dummy/default
value is needed to construct one.

## `Vector`

```
data Vector a
  = Vector (Ref (Array a)) (Ref Int)
```

`Vector backing len`: `!backing` is the capacity-sized store,
`!len` the live count; both mutated in place.

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


*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

```medaka
> capacity (fromList [1, 2, 3])
3
```

## `get`

```
get : Int -> Vector a -> Option a
```

Element at an index, or `None` when out of the live range `[0, length)`.


*(doctest — run by `medaka test`)*

```medaka
> get 1 (fromList [10, 20, 30])
Some 20
> get 5 (fromList [10, 20, 30])
None
```

## `Index (Vector a) Int a`

```
impl Index (Vector a) Int a
```

`index ma i` reads `ma`'s element at `i` (`ma[i]` sugar dispatches here),
over the live range `[0, length)`.  O(1).  Raises the coded `indexError`
(E-INDEX-OOB) when `i` is out of range -- use `get` for a safe
`Option`-returning read instead.

## `first`

```
first : Vector a -> Option a
```

First element, or `None` when empty.


*(doctest — run by `medaka test`)*

```medaka
> first (fromList [10, 20, 30])
Some 10
```

## `last`

```
last : Vector a -> Option a
```

Last element, or `None` when empty.


*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

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

## `IndexMut (Vector a) Int a`

```
impl IndexMut (Vector a) Int a
```

`setIndex ma i v` writes `v` at `ma`'s index `i`, in place, over the live
range `[0, length)`, and returns `ma`.  O(1).  Raises the coded
`indexError` (E-INDEX-OOB) when `i` is out of range.

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


*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

```medaka
> let ma = fromList [1, 2, 3] in let _ = removeAt 1 ma in toList ma
[1, 3]
> let ma = fromList [1, 2] in let _ = removeAt 7 ma in toList ma
[1, 2]
```

## `sortBy`

```
sortBy : (a -> a -> Ordering) -> Vector a -> Unit
```

Sort the live range in place with the supplied comparison.  Stable --
equal elements keep their original relative order -- because `list.sortBy`,
which does the work, is.


*(doctest — run by `medaka test`)*

```medaka
> let ma = fromList [3, 1, 4, 1, 5] in let _ = sortBy compare ma in toList ma
[1, 1, 3, 4, 5]
```

## `sort`

```
sort : Vector a -> Unit
```

Sort the live range in place by the `Ord` instance.


*(doctest — run by `medaka test`)*

```medaka
> let ma = fromList [3, 1, 2] in let _ = sort ma in toList ma
[1, 2, 3]
```

## `Foldable Vector`

```
impl Foldable Vector
```

Folds over the live range (in order), so `toList`/`length`/`sum`/`elem`/
`any`/… all work on a `Vector`.


*(doctest — run by `medaka test`)*

```medaka
> sum (fromList [1, 2, 3, 4])
10
> length (fromList [9, 8, 7])
3
```

## `Eq (Vector a)`

```
impl Eq (Vector a) requires Eq a
```

Element-wise equality over the live ranges (capacity is irrelevant).


*(doctest — run by `medaka test`)*

```medaka
> eq (fromList [1, 2, 3]) (fromList [1, 2, 3])
True
```

## `Debug (Vector a)`

```
impl Debug (Vector a) requires Debug a
```

Rendered as `fromList [a, …]` over the live range.


*(doctest — run by `medaka test`)*

```medaka
> debug (fromList [1, 2, 3]) == "fromList [1, 2, 3]"
True
```

## `Display (Vector a)`

```
impl Display (Vector a) requires Display a
```

Same `fromList [...]` shape as `Debug`, over the live range, with the
elements rendered by THEIR `Display` (so strings lose their quotes).
`Vector` was the one container in the surface that `println` could not
take (sheet row A-4).


*(doctest — run by `medaka test`)*

```medaka
> display (fromList [1, 2, 3]) == "fromList [1, 2, 3]"
True
```

