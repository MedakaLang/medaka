# mut_array

mut_array.mdk — a growable mutable array (dynamic array / vector).

`Array a` (Module 4) is **fixed-size**: O(1) random access, but no `push`/
`pop`.  `MutArray a` is the growable counterpart — a vector backed by an
`Array a` with spare capacity, so `push` is amortized O(1) (the backing
doubles when full, like the hash tables in Module 6).  Reach for `Array` when
the length is known up front; reach for `MutArray` when you accumulate.

Representation: `MutArray backing len` where `!backing` is the backing
array (its `arrayLength` is the *capacity*) and `!len` is the number of
live elements (`0 <= len <= capacity`).  Both are `Ref`s, mutated in place.
Slots `[len, capacity)` are scratch — never read; they hold
whatever value last filled them (the most recent `push`'s element on a grow).

Iteration / instances only ever touch the live range `[0, len)`, so the
scratch tail is invisible.  `empty`/`new` start at capacity 0 and allocate on
first `push`, using the pushed element as the fill — so no dummy/default
value is needed to construct one.

## `MutArray`

```
data MutArray a
  = MutArray (Ref (Array a)) (Ref Int)
```

`MutArray backing len`: `!backing` is the capacity-sized store,
`!len` the live count; both mutated in place.

## `new`

```
new : Unit -> MutArray a
```

A fresh, empty vector (capacity 0; grows on first `push`).  Takes `Unit`,
not a nullary value, so each call allocates its own cells.

## `fromList`

```
fromList : List a -> MutArray a
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
fromArray : Array a -> MutArray a
```

Wrap a *copy* of an array as a vector (so later mutation does not disturb
the caller's array).

## `capacity`

```
capacity : MutArray a -> Int
```

Capacity of the backing store (`>= length`).  Grows by doubling.


*(doctest — run by `medaka test`)*

```medaka
> capacity (fromList [1, 2, 3])
3
```

## `get`

```
get : Int -> MutArray a -> Option a
```

Element at an index, or `None` when out of the live range `[0, length)`.


*(doctest — run by `medaka test`)*

```medaka
> get 1 (fromList [10, 20, 30])
Some 20
> get 5 (fromList [10, 20, 30])
None
```

## `Index (MutArray a) Int a`

```
impl Index (MutArray a) Int a
```

`index ma i` reads `ma`'s element at `i` (`ma[i]` sugar dispatches here),
over the live range `[0, length)`.  O(1).  Raises the coded `indexError`
(E-INDEX-OOB) when `i` is out of range -- use `get` for a safe
`Option`-returning read instead.

## `first`

```
first : MutArray a -> Option a
```

First element, or `None` when empty.


*(doctest — run by `medaka test`)*

```medaka
> first (fromList [10, 20, 30])
Some 10
```

## `last`

```
last : MutArray a -> Option a
```

Last element, or `None` when empty.


*(doctest — run by `medaka test`)*

```medaka
> last (fromList [10, 20, 30])
Some 30
```

## `toArray`

```
toArray : MutArray a -> Array a
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
push : a -> MutArray a -> Unit
```

Append an element, growing (doubling) the backing store when it is full.
Amortized O(1).

## `pop`

```
pop : MutArray a -> Option a
```

Remove and return the last element, or `None` when empty.  Keeps capacity
(no shrink).

## `set`

```
set : Int -> a -> MutArray a -> Unit
```

Overwrite the element at an index.  Panics when out of the live range
`[0, length)` (use `push` to extend).

## `IndexMut (MutArray a) Int a`

```
impl IndexMut (MutArray a) Int a
```

`setIndex ma i v` writes `v` at `ma`'s index `i`, in place, over the live
range `[0, length)`, and returns `ma`.  O(1).  Raises the coded
`indexError` (E-INDEX-OOB) when `i` is out of range.

## `swap`

```
swap : Int -> Int -> MutArray a -> Unit
```

Exchange the elements at two indices.  Caller ensures both are in range.

## `clear`

```
clear : MutArray a -> Unit
```

Drop all elements (length 0), retaining the allocated capacity.

## `mapInPlace`

```
mapInPlace : (a -> a) -> MutArray a -> Unit
```

Apply `f` to every live element in place.

## `Foldable MutArray`

```
impl Foldable MutArray
```

Folds over the live range (in order), so `toList`/`length`/`sum`/`elem`/
`any`/… all work on a `MutArray`.


*(doctest — run by `medaka test`)*

```medaka
> sum (fromList [1, 2, 3, 4])
10
> length (fromList [9, 8, 7])
3
```

## `Eq (MutArray a)`

```
impl Eq (MutArray a) requires Eq a
```

Element-wise equality over the live ranges (capacity is irrelevant).


*(doctest — run by `medaka test`)*

```medaka
> eq (fromList [1, 2, 3]) (fromList [1, 2, 3])
True
```

## `Debug (MutArray a)`

```
impl Debug (MutArray a) requires Debug a
```

Rendered as `fromList [a, …]` over the live range.


*(doctest — run by `medaka test`)*

```medaka
> debug (fromList [1, 2, 3]) == "fromList [1, 2, 3]"
True
```

