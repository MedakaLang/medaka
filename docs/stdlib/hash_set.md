# hash_set

hash_set.mdk — a mutable hash set (Module 6).

See STDLIB.md (Module 6) for the plan.

`HashSet a` is a **mutable** hash set — separate chaining (each bucket a
`List a`) in a `Ref`-held array plus a `Ref Int` count, mirroring
`hash_map.mdk`. The *performance* counterpart to the persistent ordered `Set`
(set.mdk): O(1) average membership/insert, updates mutate in place.

Standalone rather than a wrapper over `HashMap a Unit` — same reasoning as
set.mdk over `Map a Unit` (self-contained, no qualified-import gymnastics, no
`Unit` payload). Elements hash via the `Hashable` typeclass method `hash`,
which must agree with the element's `Eq`. A custom element type gets a
structural impl from `deriving (Hashable)` (#422); hand-write `impl Hashable
T` only when the derived fold is not what you want. A hash may be NEGATIVE
(the fold wraps) — `slotOf` masks the sign off before indexing, so that is
safe (#416). Iteration order is unspecified.

`Foldable HashSet` makes `toList`/`elem`/`length`/`any`/… work (a set's
elements *are* its `toList`, unlike a map's pairs).

## `HashSet`

```
data HashSet a
  = HashSet (Ref (Array (List a))) (Ref Int)
```

`HashSet buckets count`: chains in `!buckets`, live count in
`!count`; both mutated in place.

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


*(doctest — run by `medaka test`)*

```medaka
> size (fromList [1, 2, 3, 2, 1])
3
```

## `has`

```
has : a -> HashSet a -> Bool
```

`True` when the element is present.


*(doctest — run by `medaka test`)*

```medaka
> has 2 (fromList [1, 2, 3])
True
> has 9 (fromList [1, 2, 3])
False
```

## `insertInPlace`

```
insertInPlace : a -> HashSet a -> Unit
```

Add an element, in place. A no-op when already present. Resizes (doubling)
past load factor 0.75.

## `fromList`

```
fromList : List a -> HashSet a
```

Build a set from a list, dropping duplicates.


*(doctest — run by `medaka test`)*

```medaka
> size (fromList [1, 2, 3, 4, 5, 6, 7, 8, 8, 1])
8
```

## `deleteInPlace`

```
deleteInPlace : a -> HashSet a -> Unit
```

Remove an element, in place. A no-op when absent.

## `Foldable HashSet`

```
impl Foldable HashSet
```

Folds over elements (unspecified order), so `toList`/`length`/`elem`/`any`/
`sum`/… all work on a HashSet.


*(doctest — run by `medaka test`)*

```medaka
> toList (fromList [1, 1, 2]) /= []
True
> length (fromList [3, 1, 2, 1])
3
```

## `Eq (HashSet a)`

```
impl Eq (HashSet a) requires Eq a, Hashable a
```

Order-independent equality: same elements regardless of layout.


*(doctest — run by `medaka test`)*

```medaka
> eq (fromList [1, 2, 3]) (fromList [3, 2, 1, 2])
True
```

## `Debug (HashSet a)`

```
impl Debug (HashSet a) requires Debug a
```

Rendered `fromList [a, …]` in hash order (layout-dependent; use `eq` for
equality).

## `Display (HashSet a)`

```
impl Display (HashSet a) requires Display a, Ord a
```

The *display* form, peer of `Display (Set a)`'s `Set { x, … }`, with the
elements in ascending order so the text depends only on the value and not
on the table's internal layout.


*(doctest — run by `medaka test`)*

```medaka
> display (fromList [3, 1, 2]) == "HashSet { 1, 2, 3 }"
True
> display (new () : HashSet Int) == "HashSet {}"
True
```

