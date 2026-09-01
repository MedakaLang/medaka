# Working with Data

This chapter is about the containers you keep data in and the handful of functions
you push it through. There is little new syntax. Most of the chapter is vocabulary,
and most of that vocabulary comes from a few interfaces in the style of chapter 5.

## `List`, `Array`, and `Vector`

Medaka has three sequence types, and the choice between them is about cost.

`List a` is a singly linked list, written `[1, 2, 3]`. Adding an element to the
front with `::` is constant time, it pattern-matches as head and tail, and it is
immutable. It is the default, and nearly everything in this guide is a `List`.

`Array a` is a contiguous block of fixed length, written `[|1, 2, 3|]`. Reading an
element by index is constant time, and so is writing one in place, but the length
never changes.

`Vector a`, from the `vector` module, is an array that grows. Use it when you are
accumulating an unknown number of elements and want indexed access afterwards.

```medaka
import array as A
import vector as V

main =
  let xs = [3, 1, 2]
  println (0::xs)
  let arr = A.fromList xs
  arr[0] := 99
  println arr
  println arr[1]
  println (A.get 5 arr)
  A.sortInPlace arr
  println arr
  println (toList arr)
  let v = V.new ()
  V.push "a" v
  V.push "b" v
  println (length v)
  println (V.pop v)
```

```medaka-expect
[0, 3, 1, 2]
[|99, 1, 2|]
1
None
[|1, 2, 99|]
[1, 2, 99]
2
Some b
```

Use `List` when you build a sequence by walking it. Use `Array` when you need
indexed access or in-place updates over a fixed number of slots. `arr[i] := v` writes
in place and returns `Unit`; `arr[i]` reads an element. `A.get` returns an `Option`
instead, because an out-of-range index has no answer. Reach for `arr[i]` when you
know the index is in bounds and `A.get` when you do not. That pattern, a total
function returning `Option` instead of a partial one that crashes, runs through the
whole standard library.

The example also shows why the imports are qualified. `list` and `array` export many
of the same names (`get`, `take`, `drop`, `sort`, `sortBy`), so if you wildcard-import
both, using one of those names is an error at the use site:

```
probe.mdk:4:16: Ambiguous occurrence: 'get' is exported by both `list` and `array`.
Qualify, or select with `import <mod>.{get}`
```

`import array as A` gives you a prefix and avoids the question.

> ⚠️ **A module alias qualifies values, not types.** `import map as M` lets you
> write `M.get`, but `M.Map String Int` in a type is a parse error. Import the type
> by name on its own line, `import map.{Map}`, alongside the alias.
>
> ```
> error: probe.mdk:3:9: unexpected `.`
>   |
> 3 | sizes : M.Map String Int
>   |          ^
> ```

## `map`, `filter`, and `fold`

These three cover most of what you do with a container, and they read best in a
chain of pipes.

```medaka
main =
  println ([1, 2, 3, 4] |> map (x => x * x))
  println ([1, 2, 3, 4] |> filter (x => x > 2))
  println ([1, 2, 3, 4] |> fold (+) 0)
  println
    ([1, 2, 3, 4] |> map (x => x * x) |> filter (x => x > 5) |> fold (+) 0)
```

```medaka-expect
[1, 4, 9, 16]
[3, 4]
10
25
```

`fold` takes a combining function, a starting value, and the container:
`fold (acc x => …) start xs`. The accumulator is the function's first argument.
Other languages call this `reduce`.

None of the three is specific to `List`. `map` is the method of the `Mappable`
interface, `filter` of `Filterable`, and `fold` of `Foldable`, which also provides
`length`, `toList`, `isEmpty`, and `foldRight`. Any type that implements one of
those interfaces gets its vocabulary. That is why `toList` worked on an `Array`
above, and why `Option`, a container of at most one thing, answers to `map` and
`fold`:

```medaka
main =
  println (map (x => x + 1) (Some 1))
  println (fold (+) 0 (Some 7))
  println (length (Some 7))
  println (length (None : Option Int))
```

```medaka-expect
Some 2
7
1
0
```

`Option` is `Mappable` and `Foldable` but not `Filterable`, because a container with
a fixed shape has nowhere to put "one fewer element". The interfaces are separate so
that a type can implement the ones that make sense for it.

> **Coming from Haskell?** `map` is `fmap`, not the list-only one. `fold` is
> `foldl'` with the arguments in the order you would guess. There is no
> `Data.List.map` versus `Prelude.map` split.

Ranges build lists and arrays of numbers:

```medaka
main =
  println [1..5]
  println [1..=5]
  println [|1..=4|]
```

```medaka-expect
[1, 2, 3, 4]
[1, 2, 3, 4, 5]
[|1, 2, 3, 4|]
```

`[a..b]` stops before `b` and `[a..=b]` includes it. The `[| … |]` form gives an
array.

## `Map` and `Set`

`Map k v` and `Set a` are immutable ordered trees, so their keys need `Ord`. Both
have literal syntax. Both need the module and the type imported by name, since a bare
`import map` binds nothing.

```medaka
import map.{Map, get}
import set.{Set, has, size}

main =
  println (get "b" Map { "a" => 1, "b" => 2 })
  println (get "z" Map { "a" => 1, "b" => 2 })
  println (has 2 Set { 1, 2, 3 })
  println (size Set { 1, 2, 2, 3 })
```

```medaka-expect
Some 2
None
True
3
```

`get` returns an `Option`, and a `Set` drops duplicates, which is why the last line
is 3 rather than 4.

When you are building a large table and do not need ordering, `hash_map` and
`hash_set` are the mutable, hash-based versions. Their APIs mirror the ones here.

## Strings

`String` is its own type, separate from lists, and string interpolation is the main
way to build one.

```medaka
import string.{split, join, trim, toFloat}

main =
  println (split "," "2026-08-01,Cafe Fish,4.50")
  println (join " | " ["a", "b", "c"])
  println (trim "   padded   ")
  println (toFloat "4.50")
```

```medaka-expect
[2026-08-01, Cafe Fish, 4.50]
a | b | c
padded
Some 4.5
```

`toFloat` returns an `Option` for the same reason `A.get` does: `toFloat "banana"`
has no answer.

Interpolation is `\{ }`, and as chapter 5 showed, it calls `display`. Anything with
a `Display` implementation can be interpolated.

> ⚠️ **`length` does not work on a `String`.** `length` is a `Foldable` method, and a
> string is not a container of characters as far as the interfaces are concerned.
> Convert with `string.toChars` first. The compiler says so:
>
> ```
> error: probe.mdk:2:18: 'length' expects a container (like List or Array) here, but
> got String. Pass a List or Array; to work over a string's characters, convert it
> with `string.toChars` first.
> ```

> **Coming from Haskell?** `String` is not `[Char]`. None of the list vocabulary
> (`map`, `length`, `::`) applies to it directly.

## The expense tracker, totaled and grouped

With that much you can answer real questions about the ledger. A total is a `fold`.
Counting a category is a `filter` followed by `length`. Grouping is a `fold` into a
`Map`.

```medaka
import map.{Map, get, toList, insertWith}

data Category = Food | Housing | Books deriving (Eq, Ord, Debug)

data Expense =
  | { date : String, payee : String, amount : Float, category : Category }

impl Display Category where
  display Food = "food"
  display Housing = "housing"
  display Books = "books"

ledger : List Expense
ledger = [
  Expense {
    date = "2026-08-01",
    payee = "Cafe Fish",
    amount = 4.5,
    category = Food,
  },
  Expense {
    date = "2026-08-02",
    payee = "Landlord",
    amount = 1200.0,
    category = Housing,
  },
  Expense {
    date = "2026-08-04",
    payee = "Cafe Fish",
    amount = 3.25,
    category = Food,
  },
  Expense {
    date = "2026-08-09",
    payee = "Bookshop",
    amount = 18.0,
    category = Books,
  },
]

total : List Expense -> Float
total xs = xs |> map (e => e.amount) |> fold (+) 0.0

byCategory : List Expense -> Map Category Float
byCategory xs = fold (m e => insertWith (+) e.category e.amount m) Map {  } xs

printAll : Display a => List a -> <IO> Unit
printAll [] = ()
printAll (x::xs) =
  println x
  printAll xs

main =
  println (total ledger)
  println (ledger |> filter (e => e.category == Food) |> length)
  printAll (toList (byCategory ledger) |> map ((c, t) => "\{c}: \{t}"))
  println (get Books (byCategory ledger))
```

```medaka-expect
1225.75
2
food: 7.75
housing: 1200.0
books: 18.0
Some 18.0
```

`insertWith (+)` is the grouping idiom: insert the amount under the category, and if
there is already an amount there, add to it instead of replacing it. `toList` on a
`Map` gives a list of pairs in key order, which is why the output follows
`Category`'s declaration order rather than the order of the ledger.

`printAll` is how you print a list one element per line: a two-clause recursive
function. `map println xs` would build a `List Unit` and discard it, and the
compiler refuses to let a statement throw away a non-`Unit` value silently.

## How do I…

| To do this | Use this |
|---|---|
| turn every element into something else | `map f xs` |
| keep some elements | `filter p xs` (`list.partition` keeps both halves) |
| combine into one value | `fold f start xs` |
| find the first match | `list.findMap`, `array.find`, `list.findIndex` |
| sort | `list.sort`, `list.sortOn f`, `array.sortInPlace` |
| remove duplicates | `list.nub`, or `set.fromList` |
| pair two sequences | `list.zip`, `list.zipWith f` |
| chop into pieces | `list.chunks n`, `list.split`, `string.split` |
| drop the `None`s from a `List (Option a)` | `list.somes` |
| split a `List (Result e a)` | `list.partitionResults` |
| build a `Map` from pairs | `map.fromList`, or the `Map { k => v }` literal |
| count occurrences | `list.tally` |

The [stdlib reference](../stdlib/index.md) lists every module and function. Before
you hand-roll a parser, look at `json`, `byteparser`, and `bytebuilder` there.

---

Nearly every function in this chapter was pure: same input, same output, nothing
touched outside the program. The exceptions were the ones that printed, and
`printAll`'s signature had to say so with `<IO>`. [Chapter 7](07-effects-and-io.md)
is about that row and what it means.
