# hash_map

A mutable hash table from keys to values.

`HashMap k v` gives `O(1)` average lookup, insertion, and deletion. The
writing operations, `setInPlace` and `deleteInPlace`, change the table in
place and return `Unit`; every other operation reads it. Iteration order
is unspecified. Use `map` instead when you want an immutable value or
ordered keys.

Keys need `Eq` and `Hashable`, and the two must agree: equal keys must
hash equally. `deriving (Hashable)` gives a key type an instance that
agrees with its derived `Eq`.

### `HashMap`

```
data HashMap k v
  = HashMap (Ref (Array (List (k, v)))) (Ref Int)
```

The hash table type. Its fields are the bucket array and the entry
count, both mutable.

Instances: [`Eq`](#eq-hashmap-k-v), [`Debug`](#debug-hashmap-k-v), [`Display`](#display-hashmap-k-v), [`Index`](#index-hashmap-k-v-k-v)

## Construction

### `new`

```
new : Unit -> HashMap k v
```

A new, empty table.

Each call allocates its own table, which is why it takes `Unit`.

```medaka
> size (new () : HashMap Int Int)
0
```

### `fromList`

```
fromList : (Eq k, Hashable k) => List (k, v) -> HashMap k v
```

A table holding the pairs of an association list.

When a key appears more than once, the later pair wins.

```medaka
> size (fromList [(1, 10), (2, 20), (1, 30)])
2
```

## Query

### `size`

```
size : HashMap k v -> Int
```

The number of entries, in `O(1)`.

```medaka
> size (fromList [(1, 10), (2, 20)])
2
```

### `isEmpty`

```
isEmpty : HashMap k v -> Bool
```

Whether the table has no entries.

```medaka
> isEmpty (new () : HashMap Int Int)
True
```

### `get`

```
get : (Eq k, Hashable k) => k -> HashMap k v -> Option v
```

The value at `key`, or `None` when the key is absent.

```medaka
> get 2 (fromList [(1, 10), (2, 20)])
Some 20
> get 9 (fromList [(1, 10), (2, 20)])
None
```

### `has`

```
has : (Eq k, Hashable k) => k -> HashMap k v -> Bool
```

Whether `key` is present.

```medaka
> has 2 (fromList [(1, 10), (2, 20)])
True
```

### `findWithDefault`

```
findWithDefault : (Eq k, Hashable k) => v -> k -> HashMap k v -> v
```

The value at `key`, or `d` when the key is absent.

```medaka
> findWithDefault 0 9 (fromList [(1, 10)])
0
```

## Insertion

### `setInPlace`

```
setInPlace : (Eq k, Hashable k) => k -> v -> HashMap k v -> Unit
```

Stores `val` at `key`, replacing any existing value.

The table is changed in place and grows as needed.

## Deletion

### `deleteInPlace`

```
deleteInPlace : (Eq k, Hashable k) => k -> HashMap k v -> Unit
```

Removes the entry at `key` from the table, in place.

Nothing happens when the key is absent.

## Iteration

### `toList`

```
toList : HashMap k v -> List (k, v)
```

The entries as pairs, in unspecified order.

```medaka
> toList (fromList [(5, 50)])
[(5, 50)]
```

### `keys`

```
keys : HashMap k v -> List k
```

The keys, in unspecified order.

```medaka
> keys (fromList [(5, 50)])
[5]
```

### `values`

```
values : HashMap k v -> List v
```

The values, in unspecified order.

```medaka
> values (fromList [(5, 50)])
[50]
```

## Instances

### `Eq (HashMap k v)`

```
impl Eq (HashMap k v) requires Eq k, Eq v, Hashable k
```

Two tables are equal when they hold the same entries, whatever their
internal layout.

```medaka
> eq (fromList [(1, 10), (2, 20)]) (fromList [(2, 20), (1, 10)])
True
```

### `Debug (HashMap k v)`

```
impl Debug (HashMap k v) requires Debug k, Debug v
```

`debug` renders a table as `fromList [(k, v), ...]` in internal order,
so the text depends on the table's layout. Compare tables with `eq`, not
by their rendering.

### `Display (HashMap k v)`

```
impl Display (HashMap k v) requires Display k, Display v, Ord k
```

`display` renders a table as `HashMap { k => v, ... }` with the entries
in ascending key order, so the text depends only on the entries.

```medaka
> display (fromList [(2, 20), (1, 10)])
"HashMap { 1 => 10, 2 => 20 }"
> display (new () : HashMap Int Int)
"HashMap {}"
```

### `Index (HashMap k v) k v`

```
impl Index (HashMap k v) k v requires Eq k, Hashable k
```

`m[k]` is the value at `k`.

Panics with an index error when the key is absent; `get` is the
`Option`-returning form.

```medaka
> (fromList [(1, 10), (2, 20)])[2]
20
```

