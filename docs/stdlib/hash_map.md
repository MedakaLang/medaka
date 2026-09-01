# hash_map

hash_map.mdk — a mutable hash table (Module 6).

See STDLIB.md (Module 6) for the plan.

`HashMap k v` is a **mutable** hash table — separate chaining (each bucket a
`List (k, v)`) in an `Array` held by a `Ref` so it can be swapped on resize,
plus a `Ref Int` count. This is the *performance* counterpart to the
persistent ordered `Map` (map.mdk): O(1) average lookup/insert, but updates
mutate in place (untracked — no effect in the signature) rather than
returning a fresh map. Reach for `Map` when you want persistence/ordering;
reach for `HashMap` when you want raw speed and a single owner.

Keys hash via the `Hashable` typeclass method `hash`. It must agree with the
key's `Eq`, which holds for every structural `Eq` impl (all the built-ins) —
a *custom* `Eq` that isn't structural would break it, so don't key a
HashMap on such a type. A custom key type gets a structural impl from
`deriving (Hashable)` (#422); hand-write `impl Hashable T` only when the
derived fold is not what you want. A hash may be NEGATIVE (the fold wraps) —
`slotOf` masks the sign off before indexing, so that is safe (#416).
Iteration order is unspecified (hash order).

The mutating ops sequence mutation statements in block bodies. A conditional
mutation whose body is a multi-statement block (`deleteAt`) uses an **else-less
`if`** (Phases 118 & 122 — both the block branch and the missing `else`
survive `medaka fmt`), dropping the noisy `| otherwise = ()`. The rest stay as
**guards**: `maybeResize` (the fmt'd else-less form would be one over-long
line, since its single-application body can't soft-break) and the recursion
base-cases (`reinsertAll`, `collectBuckets`), where `| i >= n` reads best.

## `HashMap`

```
data HashMap k v
  = HashMap (Ref (Array (List (k, v)))) (Ref Int)
```

`HashMap buckets count`: `!buckets` is the bucket array (each slot a
chain), `!count` is the live entry count. Both are mutated in place.

## `new`

```
new : Unit -> HashMap a b
```

A fresh, empty hash table. Takes `Unit` (not a nullary value) so each call
allocates its own table rather than sharing one mutable cell.

## `size`

```
size : HashMap a b -> Int
```

Number of entries. O(1).


*(doctest — run by `medaka test`)*

```medaka
> size (fromList [(1, 10), (2, 20), (1, 30)])
2
```

## `isEmpty`

```
isEmpty : HashMap a b -> Bool
```

`True` when there are no entries.


*(doctest — run by `medaka test`)*

```medaka
> isEmpty (new () : HashMap Int Int)
True
```

## `get`

```
get : a -> HashMap a b -> Option b
```

The value at a key, or `None`.


*(doctest — run by `medaka test`)*

```medaka
> get 2 (fromList [(1, 10), (2, 20)])
Some 20
> get 9 (fromList [(1, 10), (2, 20)])
None
```

## `has`

```
has : a -> HashMap a b -> Bool
```

`True` when the key is present.


*(doctest — run by `medaka test`)*

```medaka
> has 2 (fromList [(1, 10), (2, 20)])
True
```

## `findWithDefault`

```
findWithDefault : a -> b -> HashMap b a -> a
```

Value at a key, or a fallback.


*(doctest — run by `medaka test`)*

```medaka
> findWithDefault 0 9 (fromList [(1, 10)])
0
```

## `set`

```
set : a -> b -> HashMap a b -> Unit
```

Insert (or overwrite) the value at a key, in place. Resizes (doubling)
when the load factor passes 0.75.

## `fromList`

```
fromList : List (a, b) -> HashMap a b
```

Build a table from an association list (later pairs win on duplicates).


*(doctest — run by `medaka test`)*

```medaka
> size (fromList [(1, 1), (2, 2), (3, 3), (4, 4), (5, 5), (6, 6), (7, 7), (8, 8)])
8
```

## `delete`

```
delete : a -> HashMap a b -> Unit
```

Remove a key, in place. A no-op when absent.

## `entries`

```
entries : HashMap a b -> List (a, b)
```

All key/value pairs, in unspecified (hash) order.

Named `entries`, not `toList`: `toList` is a `Foldable` method (returning
*elements*), and `HashMap` isn't `Foldable` — within this file the local
`toList` would be shadowed by the method and mistyped (`List v` vs the
pairs `List (k, v)`). `toList` below is a thin exported alias, never used
internally.

## `toList`

```
toList : HashMap a b -> List (a, b)
```

Conventional alias for `entries` (all key/value pairs).

## `keys`

```
keys : HashMap a b -> List a
```

All keys, in unspecified order.


*(doctest — run by `medaka test`)*

```medaka
> keys (fromList [(5, 50)])
[5]
```

## `values`

```
values : HashMap a b -> List b
```

All values, in unspecified order.


*(doctest — run by `medaka test`)*

```medaka
> values (fromList [(5, 50)])
[50]
```

## `Eq (HashMap k v)`

```
impl Eq (HashMap k v) requires Eq k, Eq v, Hashable k
```

Order-independent equality: same entries, regardless of internal layout.


*(doctest — run by `medaka test`)*

```medaka
> eq (fromList [(1, 10), (2, 20)]) (fromList [(2, 20), (1, 10)])
True
```

## `Debug (HashMap k v)`

```
impl Debug (HashMap k v) requires Debug k, Debug v
```

Rendered as `fromList [(k, v), …]` in hash order (so the exact text is
layout-dependent — don't rely on it for equality; use `eq`).

