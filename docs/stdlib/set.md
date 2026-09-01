# set

set.mdk — an immutable, ordered set of unique elements.

See STDLIB.md (Module 5) for the plan.

Design notes
────────────
`Set a` is a *weight-balanced binary search tree* — the same Adams / Haskell
`Data.Set` scheme as `map.mdk`, but storing only an element per node (no
value). The invariants are identical:

• search:   elements in the left subtree < node element < the right
• balance:  neither subtree is more than `delta` (= 3) times the other

maintained by the smart constructor `balance`. The structure is *persistent*
(every op returns a fresh set sharing untouched subtrees), and ordering is by
the element's `Ord`, so most operations carry an `Ord a` constraint while the
pure walks (`size`, `toList`, the folds) do not.

This is a standalone tree rather than a wrapper over `Map a Unit`: it keeps
the module self-contained (no cross-module name clashes on `insert`/`union`/…)
and avoids the per-node `Unit` payload. The balancing mirrors map.mdk's,
which the property tests below re-verify.

## `Set`

```
data Set a
  = Tip
  | Bin Int a (Set a) (Set a)
```

The representation. `Tip` is the empty set; `Bin size elem left right` is an
interior node whose cached `size` is `1 + size left + size right`.

## `singleton`

```
singleton : a -> Set a
```

A set with a single element.


*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

```medaka
> size (Set { 1, 2, 3, 2, 1 })
3
> toList (fromList [3, 1, 2, 3, 1])
[1, 2, 3]
```

The empty literal `Set { }` works too (Phase 114); annotate to fix the
element type the empty braces leave open:


*(doctest — run by `medaka test`)*

```medaka
> size (Set { } : Set Int)
0
```

## `size`

```
size : Set a -> Int
```

Number of elements. O(1) — read off the root's cached size.


*(doctest — run by `medaka test`)*

```medaka
> size (fromList [1, 2, 3, 2])
3
```

## `has`

```
has : Ord a => a -> Set a -> Bool
```

`True` when the element is present.


*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

```medaka
> has 2 (delete 2 (fromList [1, 2, 3]))
False
```

Deleting an absent element leaves the set unchanged:


*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

```medaka
> minView (Set { } : Set Int)
None
```

## `maxView`

```
maxView : Set a -> Option (a, Set a)
```

Split off the largest element: `Some (elem, rest)`, or `None`.


*(doctest — run by `medaka test`)*

```medaka
> maxView (Set { } : Set Int)
None
```

## `getMin`

```
getMin : Set a -> Option a
```

Smallest element, or `None`.


*(doctest — run by `medaka test`)*

```medaka
> getMin (fromList [3, 1, 2])
Some 1
```

## `getMax`

```
getMax : Set a -> Option a
```

Largest element, or `None`.


*(doctest — run by `medaka test`)*

```medaka
> getMax (fromList [3, 1, 2])
Some 3
```

## `deleteMin`

```
deleteMin : Set a -> Set a
```

Drop the smallest element (a no-op on the empty set).


*(doctest — run by `medaka test`)*

```medaka
> toList (deleteMin (fromList [3, 1, 2]))
[2, 3]
```

## `deleteMax`

```
deleteMax : Set a -> Set a
```

Drop the largest element (a no-op on the empty set).


*(doctest — run by `medaka test`)*

```medaka
> toList (deleteMax (fromList [3, 1, 2]))
[1, 2]
```

## `union`

```
union : Ord a => Set a -> Set a -> Set a
```

Union — every element in either set.


*(doctest — run by `medaka test`)*

```medaka
> toList (union (fromList [1, 2]) (fromList [2, 3]))
[1, 2, 3]
```

Disjoint operands keep every element of both; a subset operand adds nothing:


*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

```medaka
> toList (intersection (fromList [1, 2, 3]) (fromList [2, 3, 4]))
[2, 3]
```

Disjoint operands intersect to empty; a subset operand is its own intersection:


*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

```medaka
> toList (difference (fromList [1, 2, 3]) (fromList [2]))
[1, 3]
```

Subtracting a disjoint set changes nothing; subtracting a superset empties it:


*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

```medaka
> isSubsetOf (fromList [1, 2]) (fromList [1, 2, 3])
True
> isSubsetOf (fromList [1, 4]) (fromList [1, 2, 3])
False
```

## `Foldable Set`

```
impl Foldable Set
```

`Foldable Set` folds over elements in ascending order — so `toList`,
`length`, `elem`, `sum`, `maximum`, `any`/`all`, … all work on a set. (Unlike
`Map`, whose `toList` means pairs, a set's elements *are* its `toList`, so the
Foldable methods carry the natural meaning and there's no name clash.)


*(doctest — run by `medaka test`)*

```medaka
> toList (fromList [3, 1, 2, 1])
[1, 2, 3]
> length (fromList [3, 1, 2, 1])
3
```

## `Eq (Set a)`

```
impl Eq (Set a) requires Eq a
```

Structural equality: same elements (compared through the canonical
ascending element list, so tree *shape* doesn't matter).


*(doctest — run by `medaka test`)*

```medaka
> eq (fromList [1, 2, 3]) (fromList [3, 2, 1, 2])
True
```

## `Ord (Set a)`

```
impl Ord (Set a) requires Ord a
```

Lexicographic ordering through the canonical ascending element list, so a
proper prefix sorts first.  Enables nesting (`Set (Set a)`, `Map (Set a) v`).


*(doctest — run by `medaka test`)*

```medaka
> compare (fromList [1, 2]) (fromList [1, 3])
Lt
```

## `Debug (Set a)`

```
impl Debug (Set a) requires Debug a
```

Rendered as `fromList [a, …]`, the re-evaluable form (the `Set { … }`
literal is the *display* form — see PLAN.md Phase 111). Doctest compares
against a literal: `Debug String` is out of this module's test context.


*(doctest — run by `medaka test`)*

```medaka
> debug (fromList [1, 2, 3]) == "fromList [1, 2, 3]"
True
```

## `Display (Set a)`

```
impl Display (Set a) requires Display a
```

The *display* form — the Phase-108 literal `Set { x, … }` (empty →
`Set {}`), as opposed to Debug's re-evaluable `fromList [x, …]`.


*(doctest — run by `medaka test`)*

```medaka
> display (fromList [1, 2, 3]) == "Set { 1, 2, 3 }"
True
> display (empty : Set Int) == "Set {}"
True
```

## `Semigroup (Set a)`

```
impl Semigroup (Set a) requires Ord a
```

`++` on sets is union; `append` dispatches on its first `Set` argument, so
the `Ord a` it needs threads in by the ordinary route.

## `FromEntries (Set a) a`

```
impl FromEntries (Set a) a requires Ord a
```

Backs the `Set { x, … }` literal: the compiler lowers that to
`fromEntries [x, …]` pinned at `Set`, dispatching here.

## `Monoid (Set a)`

```
impl Monoid (Set a) requires Ord a
```

`Monoid.empty` for `Set` is the empty tree (nullary, dispatched on its
result type; Phase 103). `Tip` needs no dict, so it grounds cleanly.


*(doctest — run by `medaka test`)*

```medaka
> isEmpty (empty : Set Int)
True
```

## `wellFormed`

```
wellFormed : Ord a => Set a -> Bool
```

Check the structural invariants at every node: search-tree order
(left < node < right), the cached `size`, and the weight-balance bound.
A correct sequence of operations always leaves a set `wellFormed`.


*(doctest — run by `medaka test`)*

```medaka
> wellFormed (fromList [5, 3, 8, 1, 4, 7, 9, 2, 6])
True
> wellFormed (Set { } : Set Int)
True
```

