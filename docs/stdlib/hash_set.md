# hash_set

A mutable set of distinct elements, keyed by hash.

`HashSet a` gives `O(1)` average membership, insertion, and deletion.
The writing operations, `insertInPlace` and `deleteInPlace`, change the
set in place and return `Unit`; every other operation reads it. Iteration
order is unspecified. Use `set` instead when you want an immutable value
or ordered elements.

Elements need `Eq` and `Hashable`, and the two must agree: equal elements
must hash equally. `deriving (Hashable)` gives an element type an
instance that agrees with its derived `Eq`. The `Foldable` instance
makes `toList`, `elem`, `length`, and `any` work on a set.

### `HashSet`

```
data HashSet a
  = HashSet (Ref (Array (List a))) (Ref Int)
```

The hash set type. Its fields are the bucket array and the element
count, both mutable.

Instances: [`Foldable`](#foldable-hashset), [`Eq`](#eq-hashset-a), [`Debug`](#debug-hashset-a), [`Display`](#display-hashset-a)

## Construction

### `new`

```
new : Unit -> HashSet a
```

A new, empty set.

Each call allocates its own set, which is why it takes `Unit`.

```medaka
> size (new () : HashSet Int)
0
```

### `fromList`

```
fromList : (Eq a, Hashable a) => List a -> HashSet a
```

A set holding the elements of a list, without duplicates.

```medaka
> size (fromList [1, 2, 3, 2, 1])
3
```

## Query

### `size`

```
size : HashSet a -> Int
```

The number of elements, in `O(1)`.

```medaka
> size (fromList [1, 2, 3])
3
```

### `has`

```
has : (Eq a, Hashable a) => a -> HashSet a -> Bool
```

Whether `x` is a member.

```medaka
> has 2 (fromList [1, 2, 3])
True
> has 9 (fromList [1, 2, 3])
False
```

## Insertion and deletion

### `insertInPlace`

```
insertInPlace : (Eq a, Hashable a) => a -> HashSet a -> Unit
```

Adds `x` to the set, in place.

Nothing happens when `x` is already a member. The set grows as needed.

### `deleteInPlace`

```
deleteInPlace : (Eq a, Hashable a) => a -> HashSet a -> Unit
```

Removes `x` from the set, in place.

Nothing happens when `x` is not a member.

## Instances

### `Foldable HashSet`

```
impl Foldable HashSet
```

The `Foldable` methods visit the elements in unspecified order, so
`toList`, `length`, `elem`, `any`, and `sum` work on a set.

```medaka
> length (fromList [3, 1, 2, 1])
3
```

### `Eq (HashSet a)`

```
impl Eq (HashSet a) requires Eq a, Hashable a
```

Two sets are equal when they hold the same elements, whatever their
internal layout.

```medaka
> eq (fromList [1, 2, 3]) (fromList [3, 2, 1, 2])
True
```

### `Debug (HashSet a)`

```
impl Debug (HashSet a) requires Debug a
```

`debug` renders a set as `fromList [x, ...]` in internal order, so the
text depends on the set's layout. Compare sets with `eq`, not by their
rendering.

### `Display (HashSet a)`

```
impl Display (HashSet a) requires Display a, Ord a
```

`display` renders a set as `HashSet { x, ... }` with the elements in
ascending order, so the text depends only on the elements.

```medaka
> display (fromList [3, 1, 2])
"HashSet { 1, 2, 3 }"
> display (new () : HashSet Int)
"HashSet {}"
```

