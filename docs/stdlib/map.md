# map

## `Map`

```
data Map k v
  = Tip
  | Bin Int k v (Map k v) (Map k v)
```

Instances: [`Index`](#index-map-k-v-k-v), [`Mappable`](#mappable-map-k), [`Filterable`](#filterable-map-k), [`Eq`](#eq-map-k-v), [`Ord`](#ord-map-k-v), [`Debug`](#debug-map-k-v), [`Display`](#display-map-k-v), [`Semigroup`](#semigroup-map-k-v), [`FromEntries`](#fromentries-map-k-v-k-v), [`Monoid`](#monoid-map-k-v)

## `singleton`

```
singleton : k -> v -> Map k v
```

A map with a single entry.

```medaka
> size (singleton 1 "a")
1
```

## `fromList`

```
fromList : Ord k => List (k, v) -> Map k v
```

Build a map from an association list.  Later pairs win on duplicate keys.

The `Map { k => v, … }` literal is sugar for `fromList` (it lowers to a
`FromEntries` dispatch pinned at `Map`, see the impl at the bottom of this
file):

```medaka
> size (Map { 1 => 10, 2 => 20, 3 => 30 })
3
> findWithDefault 0 2 (Map { 1 => 10, 2 => 20 })
20
```

The empty literal `Map { }` works too (Phase 114); annotate to fix the
element types the empty braces leave open:

```medaka
> size (Map { } : Map Int Int)
0
```

```medaka
> keys (fromList [(3, 0), (1, 0), (2, 0)])
[1, 2, 3]
> findWithDefault 0 1 (fromList [(1, 10), (1, 20)])
20
```

## `size`

```
size : Map k v -> Int
```

Number of entries.  O(1) — read straight off the root's cached size.

```medaka
> size (fromList [(1, 10), (2, 20), (1, 30)])
2
```

## `isEmpty`

```
isEmpty : Map k v -> Bool
```

`True` when the map has no entries.

```medaka
> isEmpty (empty : Map Int Int)
True
```

## `get`

```
get : Ord k => k -> Map k v -> Option v
```

Look up the value at a key.

```medaka
> get 2 (fromList [(1, 10), (2, 20)])
Some 20
> get 9 (fromList [(1, 10), (2, 20)])
None
```

## `has`

```
has : Ord k => k -> Map k v -> Bool
```

`True` when the key is present.

```medaka
> has 2 (fromList [(1, 10), (2, 20)])
True
> has 9 (fromList [(1, 10), (2, 20)])
False
```

## `findWithDefault`

```
findWithDefault : Ord k => v -> k -> Map k v -> v
```

Value at a key, or a fallback when the key is absent.

```medaka
> findWithDefault 0 2 (fromList [(1, 10), (2, 20)])
20
> findWithDefault 0 9 (fromList [(1, 10), (2, 20)])
0
```

## `set`

```
set : Ord k => k -> v -> Map k v -> Map k v
```

Insert a key/value pair, replacing any existing value at the key.

```medaka
> findWithDefault 0 2 (set 2 99 (fromList [(1, 10), (2, 20)]))
99
```

## `insertWith`

```
insertWith : Ord k => (v -> v -> v) -> k -> v -> Map k v -> Map k v
```

Insert with a combining function.  On a collision the new value is
`f newValue oldValue`; on a fresh key the value is stored as-is.

```medaka
> findWithDefault 0 1 (insertWith (n o => n + o) 1 5 (fromList [(1, 10)]))
15
```

## `adjust`

```
adjust : Ord k => (v -> v) -> k -> Map k v -> Map k v
```

Apply a function to the value at a key, if present.  A no-op when the key
is absent.  The tree shape is unchanged, so no rebalancing is needed.

```medaka
> findWithDefault 0 1 (adjust (n => n * 10) 1 (fromList [(1, 5), (2, 6)]))
50
```

## `delete`

```
delete : Ord k => k -> Map k v -> Map k v
```

Remove a key.  A no-op when the key is absent.

```medaka
> has 2 (delete 2 (fromList [(1, 10), (2, 20)]))
False
> size (delete 9 (fromList [(1, 10), (2, 20)]))
2
```

## `minView`

```
minView : Map k v -> Option (k, v, Map k v)
```

Split off the smallest entry: `Some (key, value, rest)`, or `None` when
empty.  `rest` stays balanced.

## `maxView`

```
maxView : Map k v -> Option (k, v, Map k v)
```

Split off the largest entry: `Some (key, value, rest)`, or `None`.

## `getMin`

```
getMin : Map k v -> Option (k, v)
```

Smallest key/value, or `None`.

```medaka
> getMin (fromList [(3, 0), (1, 0), (2, 0)])
Some (1, 0)
```

## `getMax`

```
getMax : Map k v -> Option (k, v)
```

Largest key/value, or `None`.

```medaka
> getMax (fromList [(3, 0), (1, 0), (2, 0)])
Some (3, 0)
```

## `deleteMin`

```
deleteMin : Map k v -> Map k v
```

Drop the smallest entry (a no-op on the empty map).

```medaka
> keys (deleteMin (fromList [(3, 0), (1, 0), (2, 0)]))
[2, 3]
```

## `deleteMax`

```
deleteMax : Map k v -> Map k v
```

Drop the largest entry (a no-op on the empty map).

```medaka
> keys (deleteMax (fromList [(3, 0), (1, 0), (2, 0)]))
[1, 2]
```

## `foldrWithKey`

```
foldrWithKey : (k -> v -> b -> <e> b) -> b -> Map k v -> <e> b
```

Right fold over key/value pairs in ascending key order.

## `foldlWithKey`

```
foldlWithKey : (b -> k -> v -> <e> b) -> b -> Map k v -> <e> b
```

Left fold over key/value pairs in ascending key order.

## `toList`

```
toList : Map k v -> List (k, v)
```

All key/value pairs, ascending by key.

```medaka
> toList (fromList [(2, 20), (1, 10), (3, 30)])
[(1, 10), (2, 20), (3, 30)]
```

## `keys`

```
keys : Map k v -> List k
```

All keys, ascending.

```medaka
> keys (fromList [(2, 0), (3, 0), (1, 0)])
[1, 2, 3]
```

## `values`

```
values : Map k v -> List v
```

All values, ordered by their keys.

```medaka
> values (fromList [(2, 20), (1, 10), (3, 30)])
[10, 20, 30]
```

## `mapWithKey`

```
mapWithKey : (k -> v -> <e> w) -> Map k v -> <e> Map k w
```

Map a function over the values, keeping keys and structure.  The key is
passed alongside the value.

```medaka
> values (mapWithKey (k v => k + v) (fromList [(1, 10), (2, 20)]))
[11, 22]
```

## `filterWithKey`

```
filterWithKey : Ord k => (k -> v -> <e> Bool) -> Map k v -> <e> Map k v
```

Keep only the entries whose key/value satisfy the predicate.

```medaka
> keys (filterWithKey (k v => v > 15) (fromList [(1, 10), (2, 20), (3, 30)]))
[2, 3]
```

## `union`

```
union : Ord k => Map k v -> Map k v -> Map k v
```

Left-biased union: on a shared key the value from the first map wins.

```medaka
> findWithDefault 0 1 (union (fromList [(1, 1)]) (fromList [(1, 2), (2, 2)]))
1
> size (union (fromList [(1, 1)]) (fromList [(1, 2), (2, 2)]))
2
```

## `unionWith`

```
unionWith : Ord k => (v -> v -> v) -> Map k v -> Map k v -> Map k v
```

Union with a combining function for shared keys: `f leftValue rightValue`.

```medaka
> findWithDefault 0 1 (unionWith (x y => x + y) (fromList [(1, 1)]) (fromList [(1, 2)]))
3
```

## `difference`

```
difference : Ord k => Map k v -> Map k w -> Map k v
```

Keys present in the first map but not the second (values from the first).

```medaka
> keys (difference (fromList [(1, 0), (2, 0), (3, 0)]) (fromList [(2, 0)]))
[1, 3]
```

## `intersectionWith`

```
intersectionWith : Ord k => (v -> w -> x) -> Map k v -> Map k w -> Map k x
```

Keys present in both maps, combined with `f leftValue rightValue`.

```medaka
> toList (intersectionWith (x y => x + y) (fromList [(1, 10), (2, 20)]) (fromList [(2, 2), (3, 3)]))
[(2, 22)]
```

## `intersection`

```
intersection : Ord k => Map k v -> Map k w -> Map k v
```

Keys present in both maps, keeping the LEFT map's value — the plain form
of `intersectionWith`, matching how `union` is the plain form of
`unionWith` and how `set.intersection` is left-biased.

```medaka
> toList (intersection (fromList [(1, 10), (2, 20)]) (fromList [(2, 2), (3, 3)]))
[(2, 20)]
```

## `wellFormed`

```
wellFormed : Ord k => Map k v -> Bool
```

Check the three structural invariants at every node: the search-tree
order (left keys < node key < right keys), the cached `size` matching the
actual subtree size, and the weight-balance bound (neither sibling more than
`delta` times the other).  A correct sequence of operations always leaves a
map `wellFormed`; it is exported as a debugging aid and as the backbone of
this module's property tests.  Re-walks subtrees for the order check, so it
is O(n log n) — not for hot paths.

## Instances

### `Index (Map k v) k v`

```
impl Index (Map k v) k v requires Ord k
```

`index m k` looks up `m`'s value at key `k` (`m[k]` sugar dispatches
here).  Raises the coded `indexError` (E-INDEX-OOB) when the key is
absent -- use `get` for a safe `Option`-returning read instead.  Note the
flipped argument order vs. `get k m`: the `Index` interface always takes
the container first (`index m k`).

### `Mappable (Map k)`

```
impl Mappable (Map k)
```

Map over the values, keys and structure preserved.

```medaka
> values (map (n => n * 10) (fromList [(1, 1), (2, 2)]))
[10, 20]
```

### `Filterable (Map k)`

```
impl Filterable (Map k)
```

Drop (and transform) values, keys and order preserved.  `filterMap` is the
primitive; the interface's default `filter` falls out of it.  Note this
folds over VALUES — the key-aware form is the module-level `filterWithKey`,
which stays because the interface's callback cannot see a key.

### `Eq (Map k v)`

```
impl Eq (Map k v) requires Eq k, Eq v
```

Structural equality: same keys mapped to equal values.  Compared through
the canonical ascending association list, so tree *shape* doesn't matter.

```medaka
> eq (fromList [(1, 10), (2, 20)]) (fromList [(2, 20), (1, 10)])
True
```

### `Ord (Map k v)`

```
impl Ord (Map k v) requires Ord k, Ord v
```

Lexicographic ordering through the canonical ascending association list,
so two maps order by their `(key, value)` pairs and a proper prefix sorts
first.  Enables nesting (`Map (Set k) v`) and sorting `List (Map …)`.

```medaka
> compare (fromList [(1, 10)]) (fromList [(1, 20)])
Lt
```

### `Debug (Map k v)`

```
impl Debug (Map k v) requires Debug k, Debug v
```

Rendered as `fromList [(k, v), …]`, mirroring the constructor that would
rebuild it.  (Doctest compares against a literal: `Debug String` lives in
string.mdk, out of this module's isolated test context.)

```medaka
> debug (fromList [(1, 10), (2, 20)]) == "fromList [(1, 10), (2, 20)]"
True
```

### `Display (Map k v)`

```
impl Display (Map k v) requires Display k, Display v
```

The *display* form — the Phase-108 literal `Map { k => v, … }` (empty →
`Map {}`), as opposed to Debug's re-evaluable `fromList [(k, v), …]`.

```medaka
> display (fromList [(1, 10), (2, 20)]) == "Map { 1 => 10, 2 => 20 }"
True
> display (empty : Map Int Int) == "Map {}"
True
```

### `Semigroup (Map k v)`

```
impl Semigroup (Map k v) requires Ord k
```

`++` on maps is left-biased union (the left map wins on shared keys).

`append` dispatches on its first `Map` argument, so the `Ord k` it needs to
merge threads in by the ordinary route.

### `FromEntries (Map k v) (k, v)`

```
impl FromEntries (Map k v) (k, v) requires Ord k
```

Backs the `Map { k => v, … }` literal: the compiler lowers that to
`fromEntries [(k, v), …]` pinned at `Map`, dispatching here.  The `Ord k`
the build needs threads in by the ordinary return-position route.

### `Monoid (Map k v)`

```
impl Monoid (Map k v) requires Ord k
```

`Monoid.empty` for `Map` is the empty tree.  `empty` is nullary and so
dispatches on its *result* type (Phase 103); the impl's `requires Ord k`
carries no dict here because `Tip` needs none, so a return-position `empty :
Map k v` grounds cleanly.

```medaka
> isEmpty (empty : Map Int Int)
True
```

