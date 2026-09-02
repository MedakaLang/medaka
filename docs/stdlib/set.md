# set

## `Set`

```
data Set a
  = Tip
  | Bin Int a (Set a) (Set a)
```

Instances: [`Foldable`](#foldable-set), [`Eq`](#eq-set-a), [`Ord`](#ord-set-a), [`Debug`](#debug-set-a), [`Display`](#display-set-a), [`Semigroup`](#semigroup-set-a), [`FromEntries`](#fromentries-set-a-a), [`Monoid`](#monoid-set-a)

## `singleton`

```
singleton : a -> Set a
```

A set with a single element.

```medaka
> size (singleton 5)
1
```

## `fromList`

```
fromList : Ord a => List a -> Set a
```

Build a set from a list, dropping duplicates.

The `Set { x, … }` literal is sugar for `fromList` (it lowers to a
`FromEntries` dispatch pinned at `Set`, see the impl at the bottom):

```medaka
> size (Set { 1, 2, 3, 2, 1 })
3
> toList (fromList [3, 1, 2, 3, 1])
[1, 2, 3]
```

The empty literal `Set { }` works too (Phase 114); annotate to fix the
element type the empty braces leave open:

```medaka
> size (Set { } : Set Int)
0
```

## `size`

```
size : Set a -> Int
```

Number of elements. O(1) — read off the root's cached size.

```medaka
> size (fromList [1, 2, 3, 2])
3
```

## `has`

```
has : Ord a => a -> Set a -> Bool
```

`True` when the element is present.

```medaka
> has 2 (fromList [1, 2, 3])
True
> has 9 (fromList [1, 2, 3])
False
```

## `insert`

```
insert : Ord a => a -> Set a -> Set a
```

Insert an element. A no-op (structurally) when already present.

```medaka
> size (insert 2 (fromList [1, 2, 3]))
3
> size (insert 9 (fromList [1, 2, 3]))
4
```

## `delete`

```
delete : Ord a => a -> Set a -> Set a
```

Remove an element. A no-op when absent.

```medaka
> has 2 (delete 2 (fromList [1, 2, 3]))
False
```

Deleting an absent element leaves the set unchanged:

```medaka
> toList (delete 9 (fromList [1, 2, 3]))
[1, 2, 3]
> size (delete 9 (fromList [1, 2, 3]))
3
```

## `minView`

```
minView : Set a -> Option (a, Set a)
```

Split off the smallest element: `Some (elem, rest)`, or `None` when empty.

```medaka
> minView (Set { } : Set Int)
None
```

## `maxView`

```
maxView : Set a -> Option (a, Set a)
```

Split off the largest element: `Some (elem, rest)`, or `None`.

```medaka
> maxView (Set { } : Set Int)
None
```

## `getMin`

```
getMin : Set a -> Option a
```

Smallest element, or `None`.

```medaka
> getMin (fromList [3, 1, 2])
Some 1
```

## `getMax`

```
getMax : Set a -> Option a
```

Largest element, or `None`.

```medaka
> getMax (fromList [3, 1, 2])
Some 3
```

## `deleteMin`

```
deleteMin : Set a -> Set a
```

Drop the smallest element (a no-op on the empty set).

```medaka
> toList (deleteMin (fromList [3, 1, 2]))
[2, 3]
```

## `deleteMax`

```
deleteMax : Set a -> Set a
```

Drop the largest element (a no-op on the empty set).

```medaka
> toList (deleteMax (fromList [3, 1, 2]))
[1, 2]
```

## `union`

```
union : Ord a => Set a -> Set a -> Set a
```

Union — every element in either set.

```medaka
> toList (union (fromList [1, 2]) (fromList [2, 3]))
[1, 2, 3]
```

Disjoint operands keep every element of both; a subset operand adds nothing:

```medaka
> toList (union (fromList [1, 2]) (fromList [3, 4]))
[1, 2, 3, 4]
> toList (union (fromList [1, 2, 3]) (fromList [2]))
[1, 2, 3]
```

## `intersection`

```
intersection : Ord a => Set a -> Set a -> Set a
```

Intersection — elements in both sets.

```medaka
> toList (intersection (fromList [1, 2, 3]) (fromList [2, 3, 4]))
[2, 3]
```

Disjoint operands intersect to empty; a subset operand is its own intersection:

```medaka
> toList (intersection (fromList [1, 2]) (fromList [3, 4]))
[]
> toList (intersection (fromList [1, 2, 3]) (fromList [2]))
[2]
```

## `difference`

```
difference : Ord a => Set a -> Set a -> Set a
```

Difference — elements in the first set but not the second.

```medaka
> toList (difference (fromList [1, 2, 3]) (fromList [2]))
[1, 3]
```

Subtracting a disjoint set changes nothing; subtracting a superset empties it:

```medaka
> toList (difference (fromList [1, 2]) (fromList [3, 4]))
[1, 2]
> toList (difference (fromList [1, 2, 3]) (fromList [1, 2, 3]))
[]
```

## `isSubsetOf`

```
isSubsetOf : Ord a => Set a -> Set a -> Bool
```

`True` when every element of the first set is in the second.

```medaka
> isSubsetOf (fromList [1, 2]) (fromList [1, 2, 3])
True
> isSubsetOf (fromList [1, 4]) (fromList [1, 2, 3])
False
```

## `wellFormed`

```
wellFormed : Ord a => Set a -> Bool
```

Check the structural invariants at every node: search-tree order
(left < node < right), the cached `size`, and the weight-balance bound.
A correct sequence of operations always leaves a set `wellFormed`.

```medaka
> wellFormed (fromList [5, 3, 8, 1, 4, 7, 9, 2, 6])
True
> wellFormed (Set { } : Set Int)
True
```

## Instances

### `Foldable Set`

```
impl Foldable Set
```

`Foldable Set` folds over elements in ascending order — so `toList`,
`length`, `elem`, `sum`, `maximum`, `any`/`all`, … all work on a set. (Unlike
`Map`, whose `toList` means pairs, a set's elements *are* its `toList`, so the
Foldable methods carry the natural meaning and there's no name clash.)

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

Structural equality: same elements (compared through the canonical
ascending element list, so tree *shape* doesn't matter).

```medaka
> eq (fromList [1, 2, 3]) (fromList [3, 2, 1, 2])
True
```

### `Ord (Set a)`

```
impl Ord (Set a) requires Ord a
```

Lexicographic ordering through the canonical ascending element list, so a
proper prefix sorts first.  Enables nesting (`Set (Set a)`, `Map (Set a) v`).

```medaka
> compare (fromList [1, 2]) (fromList [1, 3])
Lt
```

### `Debug (Set a)`

```
impl Debug (Set a) requires Debug a
```

Rendered as `fromList [a, …]`, the re-evaluable form (the `Set { … }`
literal is the *display* form — see PLAN.md Phase 111). Doctest compares
against a literal: `Debug String` is out of this module's test context.

```medaka
> debug (fromList [1, 2, 3]) == "fromList [1, 2, 3]"
True
```

### `Display (Set a)`

```
impl Display (Set a) requires Display a
```

The *display* form — the Phase-108 literal `Set { x, … }` (empty →
`Set {}`), as opposed to Debug's re-evaluable `fromList [x, …]`.

```medaka
> display (fromList [1, 2, 3]) == "Set { 1, 2, 3 }"
True
> display (empty : Set Int) == "Set {}"
True
```

### `Semigroup (Set a)`

```
impl Semigroup (Set a) requires Ord a
```

`++` on sets is union; `append` dispatches on its first `Set` argument, so
the `Ord a` it needs threads in by the ordinary route.

### `FromEntries (Set a) a`

```
impl FromEntries (Set a) a requires Ord a
```

Backs the `Set { x, … }` literal: the compiler lowers that to
`fromEntries [x, …]` pinned at `Set`, dispatching here.

### `Monoid (Set a)`

```
impl Monoid (Set a) requires Ord a
```

`Monoid.empty` for `Set` is the empty tree (nullary, dispatched on its
result type; Phase 103). `Tip` needs no dict, so it grounds cleanly.

```medaka
> isEmpty (empty : Set Int)
True
```

