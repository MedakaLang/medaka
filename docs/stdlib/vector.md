# vector

A growable, mutable array.

`Vector a` holds its elements in an array with spare capacity, so `push`
costs amortized `O(1)` and indexing is `O(1)`. The writing operations
change the vector in place and return `Unit`. Use `array` when the length
is known up front, and `Vector` when elements accumulate.

`length` is the number of elements; `capacity` is the size of the backing
store, which doubles when it fills. The `Foldable` instance makes
`toList`, `sum`, `elem`, and `any` work on a vector.

### `Vector`

```
data Vector a
  = Vector (Ref (Array a)) (Ref Int)
```

The vector type. Its fields are the backing array and the element
count, both mutable.

Instances: [`Index`](#index-vector-a-int-a), [`IndexMut`](#indexmut-vector-a-int-a), [`Foldable`](#foldable-vector), [`Eq`](#eq-vector-a), [`Debug`](#debug-vector-a), [`Display`](#display-vector-a)

## Construction

### `new`

```
new : Unit -> Vector a
```

A new, empty vector.

Each call allocates its own vector, which is why it takes `Unit`. The
backing store is allocated on the first `push`.

```medaka
> length (new () : Vector Int)
0
```

### `fromList`

```
fromList : List a -> Vector a
```

A vector holding the elements of a list, in order.

The capacity equals the length, so the next `push` grows the store.

```medaka
> length (fromList [1, 2, 3])
3
```

### `fromArray`

```
fromArray : Array a -> Vector a
```

A vector holding a copy of an array's elements.

Later changes to the vector do not affect the array.

```medaka
> toList (fromArray [|1, 2|])
[1, 2]
```

## Reading

### `capacity`

```
capacity : Vector a -> Int
```

The size of the backing store, which is at least `length`.

```medaka
> capacity (fromList [1, 2, 3])
3
```

### `get`

```
get : Int -> Vector a -> Option a
```

The element at index `i`, or `None` when `i` is out of range.

```medaka
> get 1 (fromList [10, 20, 30])
Some 20
> get 5 (fromList [10, 20, 30])
None
```

### `first`

```
first : Vector a -> Option a
```

The first element, or `None` when the vector is empty.

```medaka
> first (fromList [10, 20, 30])
Some 10
```

### `last`

```
last : Vector a -> Option a
```

The last element, or `None` when the vector is empty.

```medaka
> last (fromList [10, 20, 30])
Some 30
```

## Conversion

### `toArray`

```
toArray : Vector a -> Array a
```

A new array holding the vector's elements.

```medaka
> arrayLength (toArray (fromList [1, 2, 3]))
3
```

## Mutation

### `push`

```
push : a -> Vector a -> Unit
```

Appends `x` to the end of the vector.

Amortized `O(1)`: the backing store doubles when it is full.

```medaka
> let v = fromList [1, 2] in let _ = push 3 v in toList v
[1, 2, 3]
```

### `pop`

```
pop : Vector a -> Option a
```

Removes and returns the last element, or `None` when the vector is
empty.

The capacity is kept.

```medaka
> pop (fromList [1, 2, 3])
Some 3
```

### `setInPlace`

```
setInPlace : Int -> a -> Vector a -> Unit
```

Replaces the element at index `i` with `x`.

Panics when `i` is out of range; `push` extends the vector.

```medaka
> let v = fromList [1, 2, 3] in let _ = setInPlace 1 9 v in toList v
[1, 9, 3]
```

### `swap`

```
swap : Int -> Int -> Vector a -> Unit
```

Exchanges the elements at indices `i` and `j`.

Both indices must be in range.

```medaka
> let v = fromList [1, 2, 3] in let _ = swap 0 2 v in toList v
[3, 2, 1]
```

### `clear`

```
clear : Vector a -> Unit
```

Removes every element.

The capacity is kept.

```medaka
> let v = fromList [1, 2, 3] in let _ = clear v in length v
0
```

### `mapInPlace`

```
mapInPlace : (a -> a) -> Vector a -> Unit
```

Replaces every element with `f` applied to it.

```medaka
> let v = fromList [1, 2, 3] in let _ = mapInPlace (x => x * 10) v in toList v
[10, 20, 30]
```

## Editing and sorting

### `insertAtInPlace`

```
insertAtInPlace : Int -> a -> Vector a -> Unit
```

Inserts `x` at index `i`, shifting the following elements right.

An index at or below `0` prepends; an index at or beyond the length
appends.

```medaka
> let v = fromList [1, 2, 3] in let _ = insertAtInPlace 1 9 v in toList v
[1, 9, 2, 3]
```

### `removeAtInPlace`

```
removeAtInPlace : Int -> Vector a -> Unit
```

Removes the element at index `i`.

Nothing happens when `i` is out of range.

```medaka
> let v = fromList [1, 2, 3] in let _ = removeAtInPlace 1 v in toList v
[1, 3]
```

### `sortInPlaceBy`

```
sortInPlaceBy : (a -> a -> <e> Ordering) -> Vector a -> <e> Unit
```

Sorts the elements in place by `cmp`.

The sortInPlace is stable: elements that compare equal keep their original
order.

```medaka
> let v = fromList [3, 1, 4, 1, 5] in let _ = sortInPlaceBy compare v in toList v
[1, 1, 3, 4, 5]
```

### `sortInPlace`

```
sortInPlace : Ord a => Vector a -> Unit
```

Sorts the elements in place in ascending order.

The sortInPlace is stable.

```medaka
> let v = fromList [3, 1, 2] in let _ = sortInPlace v in toList v
[1, 2, 3]
```

## Instances

### `Index (Vector a) Int a`

```
impl Index (Vector a) Int a
```

`v[i]` is the element at index `i`, in `O(1)`.

Panics with an index error when `i` is out of range; `get` is the
`Option`-returning form.

### `IndexMut (Vector a) Int a`

```
impl IndexMut (Vector a) Int a
```

`v[i] = x` replaces the element at index `i` in place, in `O(1)`.

Panics with an index error when `i` is out of range.

### `Foldable Vector`

```
impl Foldable Vector
```

The `Foldable` methods visit the elements in order, so `toList`,
`length`, `sum`, `elem`, and `any` work on a vector.

```medaka
> sum (fromList [1, 2, 3, 4])
10
```

### `Eq (Vector a)`

```
impl Eq (Vector a) requires Eq a
```

Two vectors are equal when they hold equal elements in the same order.
Capacity does not matter.

```medaka
> eq (fromList [1, 2, 3]) (fromList [1, 2, 3])
True
```

### `Debug (Vector a)`

```
impl Debug (Vector a) requires Debug a
```

`debug` renders a vector as `fromList [x, ...]`.

```medaka
> debug (fromList [1, 2, 3])
"fromList [1, 2, 3]"
```

### `Display (Vector a)`

```
impl Display (Vector a) requires Display a
```

`display` renders a vector as `fromList [x, ...]`, with the elements
in their own `display` form.

```medaka
> display (fromList ["a", "b"])
"fromList [a, b]"
```

