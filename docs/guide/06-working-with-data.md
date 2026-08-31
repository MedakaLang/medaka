# Working with Data

You have types and you have behavior. This chapter is about the containers you keep
data in and the handful of functions you push it through. There is not much new
syntax here — the point is the vocabulary, and the fact that almost all of it comes
from a small number of interfaces you already met in
[chapter 5](05-interfaces.md).

## `List` and `Array`

Medaka gives you two sequence types, and the choice between them is a cost decision,
not a style one.

`List a` is a singly-linked cons list, written `[1, 2, 3]`. Prepending with `::` is
constant time, it pattern-matches head-and-tail, and it is immutable. It is the
default: nearly everything in this guide is a `List`.

`Array a` is a contiguous, fixed-length, *mutable* block, written `[|1, 2, 3|]`.
Indexing is constant time and writing an element in place is constant time; changing
the length is not possible at all.

```medaka
import array as A

main =
  let xs = [3, 1, 2]
  println (0 :: xs)

  let arr = A.fromList xs
  A.set 0 99 arr
  println arr
  println (A.get 1 arr)
  A.sortInPlace arr
  println arr
  println (toList arr)
```

```medaka-expect
[0, 3, 1, 2]
[|99, 1, 2|]
Some 1
[|1, 2, 99|]
[1, 2, 99]
```

Reach for `List` when you build a sequence by walking it, and for `Array` when you
need indexed access or in-place updates over a fixed number of slots. `A.set` returns
`Unit` — it mutates the array you handed it, and does not give you a new one.

`A.get` returns `Option a` rather than the element, because index 1 of an array of
length 1 has no answer. That pattern — a total function returning `Option` instead of
a partial one that crashes — runs through the whole standard library.

That example also shows the other thing you will need constantly: `array` and `list`
export a lot of the same names (`get`, `take`, `drop`, `sort`, `sortBy`), so the two
modules cannot both be wildcard-imported and used unqualified. `import list.*` next to
`import array.*` is accepted on its own — the collision is not the import, it is the
*use*, and it is reported at the reference:

```
probe.mdk:4:16: Ambiguous occurrence: 'get' is exported by both `list` and `array`.
Qualify, or select with `import <mod>.{get}`
```

`import array as A` gives you a prefix instead, and sidesteps the question entirely.

> ⚠️ **A module alias works for values, not for types.** `import map as M` lets you
> write `M.get`, but `M.Map String Int` in a *type* is a parse error. Import the type
> by name — `import map.{Map}` — alongside the alias, on its own line.
>
> ```
> error: probe.mdk:3:10: unexpected `.`
> ```

## The three functions you will actually use

`map`, `filter`, and `fold` cover most of what you want to do with a container, and
they read best chained with `|>`.

```medaka
main =
  println ([1, 2, 3, 4] |> map (x => x * x))
  println ([1, 2, 3, 4] |> filter (x => x > 2))
  println ([1, 2, 3, 4] |> fold (+) 0)
  println ([1, 2, 3, 4] |> map (x => x * x) |> filter (x => x > 5) |> fold (+) 0)
```

```medaka-expect
[1, 4, 9, 16]
[3, 4]
10
25
```

`fold` takes the combining function, a starting value, and the container:
`fold (acc x => …) start xs`. The accumulator comes first, so `fold (+) 0` and
`fold (acc x => acc ++ f x) empty` both read left to right.

None of these three is specific to `List`. `map` belongs to the `Mappable`
interface, `filter` to `Filterable`, and `fold` — along with `length`, `toList`,
`isEmpty` and `foldRight` — to `Foldable`. Anything implementing them gets the whole
vocabulary it implements — which is why `toList` worked on an `Array` above, and why
`Option`, a container of at most one thing, answers to `map` and `fold`:

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
a fixed shape has nowhere to put "one fewer element". The interfaces are separate
precisely so a type can implement the ones that make sense for it.

> **Coming from Haskell?** `map` is `fmap`, not the list-only one; `fold` is
> `foldl'` with the arguments in the order you would guess. There is no
> `Data.List.map` versus `Prelude.map` split, because the interface is the only one.

Ranges build lists (and arrays) of numbers without a loop:

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

`[a..b]` is half-open and `[a..=b]` includes the endpoint. `[| … |]` gives you the
array version of the same range.

## `Map` and `Set`

`Map k v` and `Set a` are immutable ordered trees, so their keys need `Ord`. Both
have literal syntax, and both require you to import the module *and* the type — a
bare `import map` binds no names.

```medaka
import map.{Map, get}
import set.{Set, has, size}

main =
  println (get "b" (Map { "a" => 1, "b" => 2 }))
  println (get "z" (Map { "a" => 1, "b" => 2 }))
  println (has 2 (Set { 1, 2, 3 }))
  println (size (Set { 1, 2, 2, 3 }))
```

```medaka-expect
Some 2
None
True
3
```

`get` returns `Option v`, and `Set` collapses duplicates, which is what makes the
last line `3` and not `4`.

For hash-based, mutable variants — when you are building a large table and do not
need ordering — reach for [`hash_map`](../stdlib/STDLIB.md) and `hash_set` instead;
`mut_array` is the growable-vector counterpart to `Array`. This chapter does not
cover them, and their APIs deliberately mirror the ones here.

## Strings

Strings are their own type, not a list of characters. `string` carries the operations
you expect, and interpolation is the way you build them.

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

String interpolation is `\{ }`, and — as [chapter 5](05-interfaces.md) showed — it
calls `display`. Anything with a `Display` implementation can be interpolated, and
implementing `Display` once makes a type interpolate everywhere.

> ⚠️ **`length` is a `Foldable` method, so it does not work on `String`.** A string
> is not a container of characters as far as the interface vocabulary is concerned.
> Convert first with `string.toChars`, which the compiler will tell you:
>
> ```
> error: probe.mdk:2:18: 'length' expects a container (like List or Array) here, but
> got String. Pass a List or Array; to work over a string's characters, convert it
> with `string.toChars` first.
> ```

## The expense tracker, totalled and grouped

Everything above is enough to answer real questions about the ledger. Summing is a
`fold`, counting a category is a `filter` then a `length`, and grouping is a `fold`
into a `Map`.

```medaka
import map.{Map, get, toList, insertWith}

data Category = Food | Housing | Books deriving (Eq, Ord, Debug)

data Expense =
  { date     : String
  , payee    : String
  , amount   : Float
  , category : Category
  }

impl Display Category where
  display Food    = "food"
  display Housing = "housing"
  display Books   = "books"

ledger : List Expense
ledger =
  [ Expense { date = "2026-08-01", payee = "Cafe Fish", amount = 4.50, category = Food }
  , Expense { date = "2026-08-02", payee = "Landlord", amount = 1200.0, category = Housing }
  , Expense { date = "2026-08-04", payee = "Cafe Fish", amount = 3.25, category = Food }
  , Expense { date = "2026-08-09", payee = "Bookshop", amount = 18.0, category = Books }
  ]

total : List Expense -> Float
total xs = xs |> map (e => e.amount) |> fold (+) 0.0

byCategory : List Expense -> Map Category Float
byCategory xs = fold (m e => insertWith (+) e.category e.amount m) (Map { }) xs

printAll : Display a => List a -> <IO> Unit
printAll [] = ()
printAll (x :: xs) =
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

Three things there are worth naming. `insertWith (+)` is the grouping idiom — insert
the amount at the category, and if something is already there, combine with `+`
instead of overwriting. `toList` on a `Map` gives you `List (k, v)` in key order,
which is why the output is in `Category`'s declaration order and not insertion order.
And `printAll` is how you print a list one line at a time: a two-clause recursive
function, not a loop — `map println xs` would build a `List Unit` and throw it away,
which the compiler refuses to let you do silently.

## How do I…

| …do this | …with this |
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

The full module list is in [the stdlib overview](../stdlib/STDLIB.md); `json`,
`byteparser` and `bytebuilder` live there too and are worth knowing about before you
hand-roll a parser.

---

Almost every function in this chapter has been pure: same input, same output, nothing
touched outside the program. The exception is anything that printed: every `main` above,
and `printAll`, whose signature had to say so — `Display a => List a -> <IO> Unit`. That
`<IO>` is not decoration. The next chapter is about the other kind of code —
[chapter 7, effects and IO](07-effects-and-io.md) — and it starts by contradicting
something you probably expect.
