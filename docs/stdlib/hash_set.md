# hash_set

## `HashSet`

```
data HashSet a
  = HashSet (Ref (Array (List a))) (Ref Int)
```

Instances: [`Foldable`](#foldable-hashset), [`Eq`](#eq-hashset-a), [`Debug`](#debug-hashset-a), [`Display`](#display-hashset-a)

## `new`

```
new : Unit -> HashSet a
```

A fresh, empty hash set. Takes `Unit` so each call allocates its own.

## `size`

```
size : HashSet a -> Int
```

Number of elements. O(1).

```medaka
> size (fromList [1, 2, 3, 2, 1])
3
```

## `has`

```
has : (Eq a, Hashable a) => a -> HashSet a -> Bool
```

`True` when the element is present.

```medaka
> has 2 (fromList [1, 2, 3])
True
> has 9 (fromList [1, 2, 3])
False
```

## `insertInPlace`

```
insertInPlace : (Eq a, Hashable a) => a -> HashSet a -> Unit
```

Add an element, in place. A no-op when already present. Resizes (doubling)
past load factor 0.75.

## `fromList`

```
fromList : (Eq a, Hashable a) => List a -> HashSet a
```

Build a set from a list, dropping duplicates.

```medaka
> size (fromList [1, 2, 3, 4, 5, 6, 7, 8, 8, 1])
8
```

## `deleteInPlace`

```
deleteInPlace : (Eq a, Hashable a) => a -> HashSet a -> Unit
```

Remove an element, in place. A no-op when absent.

## Instances

### `Foldable HashSet`

```
impl Foldable HashSet
```

Folds over elements (unspecified order), so `toList`/`length`/`elem`/`any`/
`sum`/… all work on a HashSet.

```medaka
> toList (fromList [1, 1, 2]) /= []
True
> length (fromList [3, 1, 2, 1])
3
```

### `Eq (HashSet a)`

```
impl Eq (HashSet a) requires Eq a, Hashable a
```

Order-independent equality: same elements regardless of layout.

```medaka
> eq (fromList [1, 2, 3]) (fromList [3, 2, 1, 2])
True
```

### `Debug (HashSet a)`

```
impl Debug (HashSet a) requires Debug a
```

Rendered `fromList [a, …]` in hash order (layout-dependent; use `eq` for
equality).

### `Display (HashSet a)`

```
impl Display (HashSet a) requires Display a, Ord a
```

The *display* form, peer of `Display (Set a)`'s `Set { x, … }`, with the
elements in ascending order so the text depends only on the value and not
on the table's internal layout.

```medaka
> display (fromList [3, 1, 2]) == "HashSet { 1, 2, 3 }"
True
> display (new () : HashSet Int) == "HashSet {}"
True
```

