# hash_map

## `HashMap`

```
data HashMap k v
  = HashMap (Ref (Array (List (k, v)))) (Ref Int)
```

Instances: [`Eq`](#eq-hashmap-k-v), [`Debug`](#debug-hashmap-k-v), [`Display`](#display-hashmap-k-v), [`Index`](#index-hashmap-k-v-k-v)

## `new`

```
new : Unit -> HashMap k v
```

A fresh, empty hash table. Takes `Unit` (not a nullary value) so each call
allocates its own table rather than sharing one mutable cell.

## `size`

```
size : HashMap k v -> Int
```

Number of entries. O(1).

```medaka
> size (fromList [(1, 10), (2, 20), (1, 30)])
2
```

## `isEmpty`

```
isEmpty : HashMap k v -> Bool
```

`True` when there are no entries.

```medaka
> isEmpty (new () : HashMap Int Int)
True
```

## `get`

```
get : (Eq k, Hashable k) => k -> HashMap k v -> Option v
```

The value at a key, or `None`.

```medaka
> get 2 (fromList [(1, 10), (2, 20)])
Some 20
> get 9 (fromList [(1, 10), (2, 20)])
None
```

## `has`

```
has : (Eq k, Hashable k) => k -> HashMap k v -> Bool
```

`True` when the key is present.

```medaka
> has 2 (fromList [(1, 10), (2, 20)])
True
```

## `findWithDefault`

```
findWithDefault : (Eq k, Hashable k) => v -> k -> HashMap k v -> v
```

Value at a key, or a fallback.

```medaka
> findWithDefault 0 9 (fromList [(1, 10)])
0
```

## `setInPlace`

```
setInPlace : (Eq k, Hashable k) => k -> v -> HashMap k v -> Unit
```

Insert (or overwrite) the value at a key, in place. Resizes (doubling)
when the load factor passes 0.75.

## `fromList`

```
fromList : (Eq k, Hashable k) => List (k, v) -> HashMap k v
```

Build a table from an association list (later pairs win on duplicates).

```medaka
> size (fromList [(1, 1), (2, 2), (3, 3), (4, 4), (5, 5), (6, 6), (7, 7), (8, 8)])
8
```

## `deleteInPlace`

```
deleteInPlace : (Eq k, Hashable k) => k -> HashMap k v -> Unit
```

Remove a key, in place. A no-op when absent.

## `toList`

```
toList : HashMap k v -> List (k, v)
```

All key/value pairs, in unspecified (hash) order.

## `keys`

```
keys : HashMap k v -> List k
```

All keys, in unspecified order.

```medaka
> keys (fromList [(5, 50)])
[5]
```

## `values`

```
values : HashMap k v -> List v
```

All values, in unspecified order.

```medaka
> values (fromList [(5, 50)])
[50]
```

## Instances

### `Eq (HashMap k v)`

```
impl Eq (HashMap k v) requires Eq k, Eq v, Hashable k
```

Order-independent equality: same entries, regardless of internal layout.

```medaka
> eq (fromList [(1, 10), (2, 20)]) (fromList [(2, 20), (1, 10)])
True
```

### `Debug (HashMap k v)`

```
impl Debug (HashMap k v) requires Debug k, Debug v
```

Rendered as `fromList [(k, v), …]` in hash order (so the exact text is
layout-dependent — don't rely on it for equality; use `eq`).

### `Display (HashMap k v)`

```
impl Display (HashMap k v) requires Display k, Display v, Ord k
```

The *display* form, peer of `Display (Map k v)`'s `Map { k => v, … }`,
with the entries in ascending KEY order so the text depends only on the
value and not on the table's internal layout.

```medaka
> display (fromList [(2, 20), (1, 10)]) == "HashMap { 1 => 10, 2 => 20 }"
True
> display (new () : HashMap Int Int) == "HashMap {}"
True
```

### `Index (HashMap k v) k v`

```
impl Index (HashMap k v) k v requires Eq k, Hashable k
```

`index m k` reads `m`'s value at key `k` (`m[k]` sugar dispatches here),
the peer of `Index (Map k v) k v`.  Raises the coded `indexError`
(E-INDEX-OOB) when the key is absent -- use `get` for a safe
`Option`-returning read instead.

```medaka
> (fromList [(1, 10), (2, 20)])[2]
20
```

