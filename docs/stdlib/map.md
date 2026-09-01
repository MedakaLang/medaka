# map

map.mdk — an immutable, ordered key→value map.

See STDLIB.md (Module 5) for the plan.

Design notes
────────────
`Map k v` is a *weight-balanced binary search tree* (the Adams / Haskell
`Data.Map` scheme): every interior node caches the size of its subtree, and
the two invariants

• search:   keys in the left subtree < node key < keys in the right
• balance:  neither subtree is more than `delta` times the size of the
other (`delta = 3`)

are maintained by a single smart constructor, `balance`, that rotates when an
insert or delete tips a node out of balance.  Caching the size makes `size`
O(1) and the balancing decision a couple of integer comparisons; it also pays
for `split`-style operations later.

The whole structure is *persistent* — every operation returns a fresh map and
shares all the untouched subtrees with the original, so an old version stays
valid and cheap to keep around.  That is exactly what a compiler's symbol
tables and scopes want.

Ordering is by the key's `Ord` instance.  Most operations therefore carry an
`Ord k` constraint; the few that only walk an existing tree (`size`, `map`,
`keys`, the folds) do not, because the tree is already in order.

## `Map`

```
data Map k v
  = Tip
  | Bin Int k v (Map k v) (Map k v)
```

The representation.  `Tip` is the empty tree; `Bin size key value left right`
is an interior node whose cached `size` is `1 + size left + size right`.
Public so callers can pattern-match if they really need to, but the smart
constructors below are the only sanctioned way to *build* one.

## `singleton`

```
singleton : a -> b -> Map a b
```

A map with a single entry.


*(doctest — run by `medaka test`)*

```medaka
> size (singleton 1 "a")
1
```

## `fromList`

```
fromList : List (a, b) -> Map a b
```

Build a map from an association list.  Later pairs win on duplicate keys.

The `Map { k => v, … }` literal is sugar for `fromList` (it lowers to a
`FromEntries` dispatch pinned at `Map`, see the impl at the bottom of this
file):


*(doctest — run by `medaka test`)*

```medaka
> size (Map { 1 => 10, 2 => 20, 3 => 30 })
3
> findWithDefault 0 2 (Map { 1 => 10, 2 => 20 })
20
```

The empty literal `Map { }` works too (Phase 114); annotate to fix the
element types the empty braces leave open:


*(doctest — run by `medaka test`)*

```medaka
> size (Map { } : Map Int Int)
0
```

*(doctest — run by `medaka test`)*

```medaka
> keys (fromList [(3, 0), (1, 0), (2, 0)])
[1, 2, 3]
> findWithDefault 0 1 (fromList [(1, 10), (1, 20)])
20
```

## `size`

```
size : Map a b -> Int
```

Number of entries.  O(1) — read straight off the root's cached size.


*(doctest — run by `medaka test`)*

```medaka
> size (fromList [(1, 10), (2, 20), (1, 30)])
2
```

## `isEmpty`

```
isEmpty : Map a b -> Bool
```

`True` when the map has no entries.


*(doctest — run by `medaka test`)*

```medaka
> isEmpty (empty : Map Int Int)
True
```

## `get`

```
get : a -> Map a b -> Option b
```

Look up the value at a key.


*(doctest — run by `medaka test`)*

```medaka
> get 2 (fromList [(1, 10), (2, 20)])
Some 20
> get 9 (fromList [(1, 10), (2, 20)])
None
```

## `Index (Map k v) k v`

```
impl Index (Map k v) k v requires Ord k
```

`index m k` looks up `m`'s value at key `k` (`m[k]` sugar dispatches
here).  Raises the coded `indexError` (E-INDEX-OOB) when the key is
absent -- use `get` for a safe `Option`-returning read instead.  Note the
flipped argument order vs. `get k m`: the `Index` interface always takes
the container first (`index m k`).

## `has`

```
has : a -> Map a b -> Bool
```

`True` when the key is present.


*(doctest — run by `medaka test`)*

```medaka
> has 2 (fromList [(1, 10), (2, 20)])
True
> has 9 (fromList [(1, 10), (2, 20)])
False
```

## `findWithDefault`

```
findWithDefault : a -> b -> Map b a -> a
```

Value at a key, or a fallback when the key is absent.


*(doctest — run by `medaka test`)*

```medaka
> findWithDefault 0 2 (fromList [(1, 10), (2, 20)])
20
> findWithDefault 0 9 (fromList [(1, 10), (2, 20)])
0
```

## `set`

```
set : a -> b -> Map a b -> Map a b
```

Insert a key/value pair, replacing any existing value at the key.


*(doctest — run by `medaka test`)*

```medaka
> findWithDefault 0 2 (set 2 99 (fromList [(1, 10), (2, 20)]))
99
```

## `insertWith`

```
insertWith : (a -> a -> a) -> b -> a -> Map b a -> Map b a
```

Insert with a combining function.  On a collision the new value is
`f newValue oldValue`; on a fresh key the value is stored as-is.


*(doctest — run by `medaka test`)*

```medaka
> findWithDefault 0 1 (insertWith (n o => n + o) 1 5 (fromList [(1, 10)]))
15
```

## `adjust`

```
adjust : (a -> a) -> b -> Map b a -> Map b a
```

Apply a function to the value at a key, if present.  A no-op when the key
is absent.  The tree shape is unchanged, so no rebalancing is needed.


*(doctest — run by `medaka test`)*

```medaka
> findWithDefault 0 1 (adjust (n => n * 10) 1 (fromList [(1, 5), (2, 6)]))
50
```

## `delete`

```
delete : a -> Map a b -> Map a b
```

Remove a key.  A no-op when the key is absent.


*(doctest — run by `medaka test`)*

```medaka
> has 2 (delete 2 (fromList [(1, 10), (2, 20)]))
False
> size (delete 9 (fromList [(1, 10), (2, 20)]))
2
```

## `minView`

```
minView : Map a b -> Option (a, b, Map a b)
```

Split off the smallest entry: `Some (key, value, rest)`, or `None` when
empty.  `rest` stays balanced.

## `maxView`

```
maxView : Map a b -> Option (a, b, Map a b)
```

Split off the largest entry: `Some (key, value, rest)`, or `None`.

## `getMin`

```
getMin : Map a b -> Option (a, b)
```

Smallest key/value, or `None`.


*(doctest — run by `medaka test`)*

```medaka
> getMin (fromList [(3, 0), (1, 0), (2, 0)])
Some (1, 0)
```

## `getMax`

```
getMax : Map a b -> Option (a, b)
```

Largest key/value, or `None`.


*(doctest — run by `medaka test`)*

```medaka
> getMax (fromList [(3, 0), (1, 0), (2, 0)])
Some (3, 0)
```

## `deleteMin`

```
deleteMin : Map a b -> Map a b
```

Drop the smallest entry (a no-op on the empty map).


*(doctest — run by `medaka test`)*

```medaka
> keys (deleteMin (fromList [(3, 0), (1, 0), (2, 0)]))
[2, 3]
```

## `deleteMax`

```
deleteMax : Map a b -> Map a b
```

Drop the largest entry (a no-op on the empty map).


*(doctest — run by `medaka test`)*

```medaka
> keys (deleteMax (fromList [(3, 0), (1, 0), (2, 0)]))
[1, 2]
```

## `foldrWithKey`

```
foldrWithKey : (a -> b -> c -> c) -> c -> Map a b -> c
```

Right fold over key/value pairs in ascending key order.

## `foldlWithKey`

```
foldlWithKey : (a -> b -> c -> a) -> a -> Map b c -> a
```

Left fold over key/value pairs in ascending key order.

## `toList`

```
toList : Map a b -> List (a, b)
```

All key/value pairs, ascending by key.


*(doctest — run by `medaka test`)*

```medaka
> toList (fromList [(2, 20), (1, 10), (3, 30)])
[(1, 10), (2, 20), (3, 30)]
```

## `keys`

```
keys : Map a b -> List a
```

All keys, ascending.


*(doctest — run by `medaka test`)*

```medaka
> keys (fromList [(2, 0), (3, 0), (1, 0)])
[1, 2, 3]
```

## `values`

```
values : Map a b -> List b
```

All values, ordered by their keys.


*(doctest — run by `medaka test`)*

```medaka
> values (fromList [(2, 20), (1, 10), (3, 30)])
[10, 20, 30]
```

## `mapWithKey`

```
mapWithKey : (a -> b -> c) -> Map a b -> Map a c
```

Map a function over the values, keeping keys and structure.  The key is
passed alongside the value.


*(doctest — run by `medaka test`)*

```medaka
> values (mapWithKey (k v => k + v) (fromList [(1, 10), (2, 20)]))
[11, 22]
```

## `filterWithKey`

```
filterWithKey : (a -> b -> Bool) -> Map a b -> Map a b
```

Keep only the entries whose key/value satisfy the predicate.


*(doctest — run by `medaka test`)*

```medaka
> keys (filterWithKey (k v => v > 15) (fromList [(1, 10), (2, 20), (3, 30)]))
[2, 3]
```

## `union`

```
union : Map a b -> Map a b -> Map a b
```

Left-biased union: on a shared key the value from the first map wins.


*(doctest — run by `medaka test`)*

```medaka
> findWithDefault 0 1 (union (fromList [(1, 1)]) (fromList [(1, 2), (2, 2)]))
1
> size (union (fromList [(1, 1)]) (fromList [(1, 2), (2, 2)]))
2
```

## `unionWith`

```
unionWith : (a -> a -> a) -> Map b a -> Map b a -> Map b a
```

Union with a combining function for shared keys: `f leftValue rightValue`.


*(doctest — run by `medaka test`)*

```medaka
> findWithDefault 0 1 (unionWith (x y => x + y) (fromList [(1, 1)]) (fromList [(1, 2)]))
3
```

## `difference`

```
difference : Map a b -> Map a c -> Map a b
```

Keys present in the first map but not the second (values from the first).


*(doctest — run by `medaka test`)*

```medaka
> keys (difference (fromList [(1, 0), (2, 0), (3, 0)]) (fromList [(2, 0)]))
[1, 3]
```

## `intersectionWith`

```
intersectionWith : (a -> b -> c) -> Map d a -> Map d b -> Map d c
```

Keys present in both maps, combined with `f leftValue rightValue`.


*(doctest — run by `medaka test`)*

```medaka
> toList (intersectionWith (x y => x + y) (fromList [(1, 10), (2, 20)]) (fromList [(2, 2), (3, 3)]))
[(2, 22)]
```

## `intersection`

```
intersection : Map a b -> Map a c -> Map a b
```

Keys present in both maps, keeping the LEFT map's value — the plain form
of `intersectionWith`, matching how `union` is the plain form of
`unionWith` and how `set.intersection` is left-biased.


*(doctest — run by `medaka test`)*

```medaka
> toList (intersection (fromList [(1, 10), (2, 20)]) (fromList [(2, 2), (3, 3)]))
[(2, 20)]
```

## `Mappable (Map k)`

```
impl Mappable (Map k)
```

Map over the values, keys and structure preserved.


*(doctest — run by `medaka test`)*

```medaka
> values (map (n => n * 10) (fromList [(1, 1), (2, 2)]))
[10, 20]
```

## `Filterable (Map k)`

```
impl Filterable (Map k)
```

Drop (and transform) values, keys and order preserved.  `filterMap` is the
primitive; the interface's default `filter` falls out of it.  Note this
folds over VALUES — the key-aware form is the module-level `filterWithKey`,
which stays because the interface's callback cannot see a key.

## `Eq (Map k v)`

```
impl Eq (Map k v) requires Eq k, Eq v
```

Structural equality: same keys mapped to equal values.  Compared through
the canonical ascending association list, so tree *shape* doesn't matter.


*(doctest — run by `medaka test`)*

```medaka
> eq (fromList [(1, 10), (2, 20)]) (fromList [(2, 20), (1, 10)])
True
```

## `Ord (Map k v)`

```
impl Ord (Map k v) requires Ord k, Ord v
```

Lexicographic ordering through the canonical ascending association list,
so two maps order by their `(key, value)` pairs and a proper prefix sorts
first.  Enables nesting (`Map (Set k) v`) and sorting `List (Map …)`.


*(doctest — run by `medaka test`)*

```medaka
> compare (fromList [(1, 10)]) (fromList [(1, 20)])
Lt
```

## `Debug (Map k v)`

```
impl Debug (Map k v) requires Debug k, Debug v
```

Rendered as `fromList [(k, v), …]`, mirroring the constructor that would
rebuild it.  (Doctest compares against a literal: `Debug String` lives in
string.mdk, out of this module's isolated test context.)


*(doctest — run by `medaka test`)*

```medaka
> debug (fromList [(1, 10), (2, 20)]) == "fromList [(1, 10), (2, 20)]"
True
```

## `Display (Map k v)`

```
impl Display (Map k v) requires Display k, Display v
```

The *display* form — the Phase-108 literal `Map { k => v, … }` (empty →
`Map {}`), as opposed to Debug's re-evaluable `fromList [(k, v), …]`.


*(doctest — run by `medaka test`)*

```medaka
> display (fromList [(1, 10), (2, 20)]) == "Map { 1 => 10, 2 => 20 }"
True
> display (empty : Map Int Int) == "Map {}"
True
```

## `Semigroup (Map k v)`

```
impl Semigroup (Map k v) requires Ord k
```

`++` on maps is left-biased union (the left map wins on shared keys).

`append` dispatches on its first `Map` argument, so the `Ord k` it needs to
merge threads in by the ordinary route.

## `FromEntries (Map k v) (k, v)`

```
impl FromEntries (Map k v) (k, v) requires Ord k
```

Backs the `Map { k => v, … }` literal: the compiler lowers that to
`fromEntries [(k, v), …]` pinned at `Map`, dispatching here.  The `Ord k`
the build needs threads in by the ordinary return-position route.

## `Monoid (Map k v)`

```
impl Monoid (Map k v) requires Ord k
```

`Monoid.empty` for `Map` is the empty tree.  `empty` is nullary and so
dispatches on its *result* type (Phase 103); the impl's `requires Ord k`
carries no dict here because `Tip` needs none, so a return-position `empty :
Map k v` grounds cleanly.


*(doctest — run by `medaka test`)*

```medaka
> isEmpty (empty : Map Int Int)
True
```

## `wellFormed`

```
wellFormed : Map a b -> Bool
```

Check the three structural invariants at every node: the search-tree
order (left keys < node key < right keys), the cached `size` matching the
actual subtree size, and the weight-balance bound (neither sibling more than
`delta` times the other).  A correct sequence of operations always leaves a
map `wellFormed`; it is exported as a debugging aid and as the backbone of
this module's property tests.  Re-walks subtrees for the order check, so it
is O(n log n) — not for hot paths.

