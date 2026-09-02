# map

An immutable map from keys to values, ordered by key.

`Map k v` is a balanced binary search tree. Lookup, insertion, and
deletion cost `O(log n)`, and `size` is `O(1)`. Every operation returns a
new map and leaves the original unchanged; the two share whatever
structure they have in common, so keeping old versions is cheap.

Keys are ordered by their `Ord` instance, and `toList`, `keys`, `values`,
and the folds visit entries in ascending key order. The `Map { k => v }`
literal builds a map; the empty map is `empty`. For keys that are
`Hashable` but not `Ord`, or when order does not matter, see
`hash_map`.

### `Map`

```
data Map k v
  = Tip
  | Bin Int k v (Map k v) (Map k v)
```

The map type.

`Tip` is the empty tree and `Bin` is an interior node holding its
subtree's size, a key, a value, and the left and right subtrees. The
constructors are visible for pattern matching, but build maps with the
functions in this module, which keep the tree balanced.

Instances: [`Index`](#index-map-k-v-k-v), [`Mappable`](#mappable-map-k), [`Filterable`](#filterable-map-k), [`Eq`](#eq-map-k-v), [`Ord`](#ord-map-k-v), [`Debug`](#debug-map-k-v), [`Display`](#display-map-k-v), [`Semigroup`](#semigroup-map-k-v), [`FromEntries`](#fromentries-map-k-v-k-v), [`Monoid`](#monoid-map-k-v)

## Construction

### `singleton`

```
singleton : k -> v -> Map k v
```

A map with one entry.

```medaka
> size (singleton 1 "a")
1
```

### `fromList`

```
fromList : Ord k => List (k, v) -> Map k v
```

A map holding the pairs of an association list.

When a key appears more than once, the later pair wins. The
`Map { k => v, ... }` literal is the same operation.

```medaka
> keys (fromList [(3, 0), (1, 0), (2, 0)])
[1, 2, 3]
> findWithDefault 0 1 (fromList [(1, 10), (1, 20)])
20
```

## Query

### `size`

```
size : Map k v -> Int
```

The number of entries, in `O(1)`.

```medaka
> size (fromList [(1, 10), (2, 20), (1, 30)])
2
```

### `isEmpty`

```
isEmpty : Map k v -> Bool
```

Whether the map has no entries.

```medaka
> isEmpty (empty : Map Int Int)
True
```

### `get`

```
get : Ord k => k -> Map k v -> Option v
```

The value at `k`, or `None` when the key is absent.

```medaka
> get 2 (fromList [(1, 10), (2, 20)])
Some 20
> get 9 (fromList [(1, 10), (2, 20)])
None
```

### `has`

```
has : Ord k => k -> Map k v -> Bool
```

Whether `k` is present.

```medaka
> has 2 (fromList [(1, 10), (2, 20)])
True
> has 9 (fromList [(1, 10), (2, 20)])
False
```

### `findWithDefault`

```
findWithDefault : Ord k => v -> k -> Map k v -> v
```

The value at `k`, or `d` when the key is absent.

```medaka
> findWithDefault 0 2 (fromList [(1, 10), (2, 20)])
20
> findWithDefault 0 9 (fromList [(1, 10), (2, 20)])
0
```

## Insertion

### `set`

```
set : Ord k => k -> v -> Map k v -> Map k v
```

The map with `v` stored at `k`, replacing any existing value.

```medaka
> findWithDefault 0 2 (set 2 99 (fromList [(1, 10), (2, 20)]))
99
```

### `insertWith`

```
insertWith : Ord k => (v -> v -> v) -> k -> v -> Map k v -> Map k v
```

The map with `v` stored at `k`, combining with an existing value.

When `k` is already present, the stored value becomes `f v old`. When it
is absent, `v` is stored as it is.

```medaka
> findWithDefault 0 1 (insertWith (n o => n + o) 1 5 (fromList [(1, 10)]))
15
```

### `adjust`

```
adjust : Ord k => (v -> v) -> k -> Map k v -> Map k v
```

The map with `f` applied to the value at `k`.

Unchanged when `k` is absent.

```medaka
> findWithDefault 0 1 (adjust (n => n * 10) 1 (fromList [(1, 5), (2, 6)]))
50
```

## Deletion

### `delete`

```
delete : Ord k => k -> Map k v -> Map k v
```

The map without the entry at `k`.

Unchanged when `k` is absent.

```medaka
> has 2 (delete 2 (fromList [(1, 10), (2, 20)]))
False
```

## Minimum and maximum

### `minView`

```
minView : Map k v -> Option (k, v, Map k v)
```

The smallest entry and the map without it, or `None` when the map is
empty.

```medaka
> minView (fromList [(2, "b"), (1, "a")])
Some (1, "a", fromList [(2, "b")])
```

### `maxView`

```
maxView : Map k v -> Option (k, v, Map k v)
```

The largest entry and the map without it, or `None` when the map is
empty.

```medaka
> maxView (fromList [(2, "b"), (1, "a")])
Some (2, "b", fromList [(1, "a")])
```

### `getMin`

```
getMin : Map k v -> Option (k, v)
```

The entry with the smallest key, or `None` when the map is empty.

```medaka
> getMin (fromList [(3, 0), (1, 0), (2, 0)])
Some (1, 0)
```

### `getMax`

```
getMax : Map k v -> Option (k, v)
```

The entry with the largest key, or `None` when the map is empty.

```medaka
> getMax (fromList [(3, 0), (1, 0), (2, 0)])
Some (3, 0)
```

### `deleteMin`

```
deleteMin : Map k v -> Map k v
```

The map without its smallest entry.

Unchanged when the map is empty.

```medaka
> keys (deleteMin (fromList [(3, 0), (1, 0), (2, 0)]))
[2, 3]
```

### `deleteMax`

```
deleteMax : Map k v -> Map k v
```

The map without its largest entry.

Unchanged when the map is empty.

```medaka
> keys (deleteMax (fromList [(3, 0), (1, 0), (2, 0)]))
[1, 2]
```

## Folds and traversal

### `foldrWithKey`

```
foldrWithKey : (k -> v -> b -> <e> b) -> b -> Map k v -> <e> b
```

A right fold over the entries in ascending key order.

```medaka
> foldrWithKey (k v acc => k :: acc) [] (fromList [(2, 0), (1, 0)])
[1, 2]
```

### `foldlWithKey`

```
foldlWithKey : (b -> k -> v -> <e> b) -> b -> Map k v -> <e> b
```

A left fold over the entries in ascending key order.

```medaka
> foldlWithKey (acc k v => acc + v) 0 (fromList [(1, 10), (2, 20)])
30
```

### `toList`

```
toList : Map k v -> List (k, v)
```

The entries as pairs, in ascending key order.

```medaka
> toList (fromList [(2, 20), (1, 10), (3, 30)])
[(1, 10), (2, 20), (3, 30)]
```

### `keys`

```
keys : Map k v -> List k
```

The keys, in ascending order.

```medaka
> keys (fromList [(2, 0), (3, 0), (1, 0)])
[1, 2, 3]
```

### `values`

```
values : Map k v -> List v
```

The values, in ascending order of their keys.

```medaka
> values (fromList [(2, 20), (1, 10), (3, 30)])
[10, 20, 30]
```

### `mapWithKey`

```
mapWithKey : (k -> v -> <e> w) -> Map k v -> <e> Map k w
```

The map with `f` applied to every value, where `f` also receives the
key.

`map` is the form whose function sees only the value.

```medaka
> values (mapWithKey (k v => k + v) (fromList [(1, 10), (2, 20)]))
[11, 22]
```

## Filtering

### `filterWithKey`

```
filterWithKey : Ord k => (k -> v -> <e> Bool) -> Map k v -> <e> Map k v
```

The entries whose key and value satisfy `p`.

`filter` is the form whose predicate sees only the value.

```medaka
> keys (filterWithKey (k v => v > 15) (fromList [(1, 10), (2, 20), (3, 30)]))
[2, 3]
```

## Combining

### `union`

```
union : Ord k => Map k v -> Map k v -> Map k v
```

The entries of both maps. On a shared key, the first map's value wins.

`++` on maps is `union`.

```medaka
> findWithDefault 0 1 (union (fromList [(1, 1)]) (fromList [(1, 2), (2, 2)]))
1
```

### `unionWith`

```
unionWith : Ord k => (v -> v -> v) -> Map k v -> Map k v -> Map k v
```

The entries of both maps. On a shared key, the value is `f left right`.

```medaka
> findWithDefault 0 1 (unionWith (x y => x + y) (fromList [(1, 1)]) (fromList [(1, 2)]))
3
```

### `difference`

```
difference : Ord k => Map k v -> Map k w -> Map k v
```

The entries of the first map whose keys are absent from the second.

```medaka
> keys (difference (fromList [(1, 0), (2, 0), (3, 0)]) (fromList [(2, 0)]))
[1, 3]
```

### `intersectionWith`

```
intersectionWith : Ord k => (v -> w -> x) -> Map k v -> Map k w -> Map k x
```

The keys present in both maps, each with the value `f left right`.

```medaka
> toList (intersectionWith (x y => x + y) (fromList [(1, 10), (2, 20)]) (fromList [(2, 2), (3, 3)]))
[(2, 22)]
```

### `intersection`

```
intersection : Ord k => Map k v -> Map k w -> Map k v
```

The keys present in both maps, each with the first map's value.

```medaka
> toList (intersection (fromList [(1, 10), (2, 20)]) (fromList [(2, 2), (3, 3)]))
[(2, 20)]
```

## Invariants

### `wellFormed`

```
wellFormed : Ord k => Map k v -> Bool
```

Whether the map's internal tree satisfies its invariants: keys in
search order, correct cached sizes, and balanced subtrees.

Every map built with this module's functions is well formed. This is a
debugging aid and the basis of the module's property tests. It costs
`O(n log n)`.

## Instances

### `Index (Map k v) k v`

```
impl Index (Map k v) k v requires Ord k
```

`m[k]` is the value at `k`.

Panics with an index error when the key is absent; `get` is the
`Option`-returning form. The `Index` interface takes the map first, so
this is `index m k` where `get` is `get k m`.

### `Mappable (Map k)`

```
impl Mappable (Map k)
```

`map` applies a function to every value, keeping the keys.

```medaka
> values (map (n => n * 10) (fromList [(1, 1), (2, 2)]))
[10, 20]
```

### `Filterable (Map k)`

```
impl Filterable (Map k)
```

`filter` and `filterMap` test each value, keeping the keys of the
entries that survive. `filterWithKey` is the form that also sees the
key.

### `Eq (Map k v)`

```
impl Eq (Map k v) requires Eq k, Eq v
```

Two maps are equal when they hold the same keys with equal values,
regardless of how they were built.

```medaka
> eq (fromList [(1, 10), (2, 20)]) (fromList [(2, 20), (1, 10)])
True
```

### `Ord (Map k v)`

```
impl Ord (Map k v) requires Ord k, Ord v
```

Maps compare lexicographically by their ascending `(key, value)` pairs.

```medaka
> compare (fromList [(1, 10)]) (fromList [(1, 20)])
Lt
```

### `Debug (Map k v)`

```
impl Debug (Map k v) requires Debug k, Debug v
```

`debug` renders a map as `fromList [(k, v), ...]`.

```medaka
> debug (fromList [(1, 10), (2, 20)])
"fromList [(1, 10), (2, 20)]"
```

### `Display (Map k v)`

```
impl Display (Map k v) requires Display k, Display v
```

`display` renders a map in its literal syntax, `Map { k => v, ... }`.

```medaka
> display (fromList [(1, 10), (2, 20)])
"Map { 1 => 10, 2 => 20 }"
> display (empty : Map Int Int)
"Map {}"
```

### `Semigroup (Map k v)`

```
impl Semigroup (Map k v) requires Ord k
```

`++` on maps is `union`: the left map wins on shared keys.

### `FromEntries (Map k v) (k, v)`

```
impl FromEntries (Map k v) (k, v) requires Ord k
```

The `Map { k => v, ... }` literal builds its map through this instance.

### `Monoid (Map k v)`

```
impl Monoid (Map k v) requires Ord k
```

`empty` is the map with no entries.

```medaka
> isEmpty (empty : Map Int Int)
True
```

