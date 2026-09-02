# set

An immutable set of distinct elements, ordered by `Ord`.

`Set a` is a balanced binary search tree. Membership, insertion, and
deletion cost `O(log n)`, and `size` is `O(1)`. Every operation returns a
new set and leaves the original unchanged; the two share whatever
structure they have in common.

`toList` and the `Foldable` methods visit elements in ascending order.
The `Set { x, ... }` literal builds a set; the empty set is `empty`. For
elements that are `Hashable` but not `Ord`, or when order does not
matter, see `hash_set`.

### `Set`

```
data Set a
  = Tip
  | Bin Int a (Set a) (Set a)
```

The set type.

`Tip` is the empty tree and `Bin` is an interior node holding its
subtree's size, an element, and the left and right subtrees. The
constructors are visible for pattern matching, but build sets with the
functions in this module, which keep the tree balanced.

Instances: [`Foldable`](#foldable-set), [`Eq`](#eq-set-a), [`Ord`](#ord-set-a), [`Debug`](#debug-set-a), [`Display`](#display-set-a), [`Semigroup`](#semigroup-set-a), [`FromEntries`](#fromentries-set-a-a), [`Monoid`](#monoid-set-a)

## Construction

### `singleton`

```
singleton : a -> Set a
```

A set with one element.

```medaka
> size (singleton 5)
1
```

### `fromList`

```
fromList : Ord a => List a -> Set a
```

A set holding the elements of a list, without duplicates.

The `Set { x, ... }` literal is the same operation.

```medaka
> toList (fromList [3, 1, 2, 3, 1])
[1, 2, 3]
```

## Query

### `size`

```
size : Set a -> Int
```

The number of elements, in `O(1)`.

```medaka
> size (fromList [1, 2, 3, 2])
3
```

### `has`

```
has : Ord a => a -> Set a -> Bool
```

Whether `x` is a member.

```medaka
> has 2 (fromList [1, 2, 3])
True
> has 9 (fromList [1, 2, 3])
False
```

## Insertion and deletion

### `insert`

```
insert : Ord a => a -> Set a -> Set a
```

The set with `x` added.

Unchanged when `x` is already a member.

```medaka
> size (insert 9 (fromList [1, 2, 3]))
4
```

### `delete`

```
delete : Ord a => a -> Set a -> Set a
```

The set without `x`.

Unchanged when `x` is not a member.

```medaka
> has 2 (delete 2 (fromList [1, 2, 3]))
False
```

## Minimum and maximum

### `minView`

```
minView : Set a -> Option (a, Set a)
```

The smallest element and the set without it, or `None` when the set is
empty.

```medaka
> minView (fromList [2, 1, 3])
Some (1, fromList [2, 3])
```

### `maxView`

```
maxView : Set a -> Option (a, Set a)
```

The largest element and the set without it, or `None` when the set is
empty.

```medaka
> maxView (fromList [2, 1, 3])
Some (3, fromList [1, 2])
```

### `getMin`

```
getMin : Set a -> Option a
```

The smallest element, or `None` when the set is empty.

```medaka
> getMin (fromList [3, 1, 2])
Some 1
```

### `getMax`

```
getMax : Set a -> Option a
```

The largest element, or `None` when the set is empty.

```medaka
> getMax (fromList [3, 1, 2])
Some 3
```

### `deleteMin`

```
deleteMin : Set a -> Set a
```

The set without its smallest element.

Unchanged when the set is empty.

```medaka
> toList (deleteMin (fromList [3, 1, 2]))
[2, 3]
```

### `deleteMax`

```
deleteMax : Set a -> Set a
```

The set without its largest element.

Unchanged when the set is empty.

```medaka
> toList (deleteMax (fromList [3, 1, 2]))
[1, 2]
```

## Set algebra

### `union`

```
union : Ord a => Set a -> Set a -> Set a
```

The elements in either set.

`++` on sets is `union`.

```medaka
> toList (union (fromList [1, 2]) (fromList [2, 3]))
[1, 2, 3]
```

### `intersection`

```
intersection : Ord a => Set a -> Set a -> Set a
```

The elements in both sets.

```medaka
> toList (intersection (fromList [1, 2, 3]) (fromList [2, 3, 4]))
[2, 3]
```

### `difference`

```
difference : Ord a => Set a -> Set a -> Set a
```

The elements of the first set that are not in the second.

```medaka
> toList (difference (fromList [1, 2, 3]) (fromList [2]))
[1, 3]
```

### `isSubsetOf`

```
isSubsetOf : Ord a => Set a -> Set a -> Bool
```

Whether every element of the first set is in the second.

```medaka
> isSubsetOf (fromList [1, 2]) (fromList [1, 2, 3])
True
> isSubsetOf (fromList [1, 4]) (fromList [1, 2, 3])
False
```

## Invariants

### `wellFormed`

```
wellFormed : Ord a => Set a -> Bool
```

Whether the set's internal tree satisfies its invariants: elements in
search order, correct cached sizes, and balanced subtrees.

Every set built with this module's functions is well formed. This is a
debugging aid and the basis of the module's property tests.

```medaka
> wellFormed (fromList [5, 3, 8, 1, 4, 7, 9, 2, 6])
True
```

## Instances

### `Foldable Set`

```
impl Foldable Set
```

The `Foldable` methods visit elements in ascending order, so `toList`,
`length`, `elem`, `sum`, `maximum`, `any`, and `all` work on a set.

```medaka
> toList (fromList [3, 1, 2, 1])
[1, 2, 3]
> length (fromList [3, 1, 2, 1])
3
```

### `Eq (Set a)`

```
impl Eq (Set a) requires Eq a
```

Two sets are equal when they hold the same elements, regardless of how
they were built.

```medaka
> eq (fromList [1, 2, 3]) (fromList [3, 2, 1, 2])
True
```

### `Ord (Set a)`

```
impl Ord (Set a) requires Ord a
```

Sets compare lexicographically by their ascending element lists.

```medaka
> compare (fromList [1, 2]) (fromList [1, 3])
Lt
```

### `Debug (Set a)`

```
impl Debug (Set a) requires Debug a
```

`debug` renders a set as `fromList [x, ...]`.

```medaka
> debug (fromList [1, 2, 3])
"fromList [1, 2, 3]"
```

### `Display (Set a)`

```
impl Display (Set a) requires Display a
```

`display` renders a set in its literal syntax, `Set { x, ... }`.

```medaka
> display (fromList [1, 2, 3])
"Set { 1, 2, 3 }"
> display (empty : Set Int)
"Set {}"
```

### `Semigroup (Set a)`

```
impl Semigroup (Set a) requires Ord a
```

`++` on sets is `union`.

### `FromEntries (Set a) a`

```
impl FromEntries (Set a) a requires Ord a
```

The `Set { x, ... }` literal builds its set through this instance.

### `Monoid (Set a)`

```
impl Monoid (Set a) requires Ord a
```

`empty` is the set with no elements.

```medaka
> isEmpty (empty : Set Int)
True
```

