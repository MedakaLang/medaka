# `do` and Thenables

Chapter 7 said what `do` is not. This chapter says what it is. `do` is syntax for
chaining computations that carry a context: a value that might be missing, a value
that might be an error, a computation with several possible answers. Inside a `do`
block, the chaining reads like ordinary sequential code and the context handling
disappears.

No `do` block in this chapter performs IO. Where an example prints, the printing
happens in `main`, outside the chain.

## The problem

Three lookups, each of which can fail. Written by hand, the plumbing is most of the
program:

```medaka
import map.{Map, get}
import map as M

prices : Map String Float
prices = M.fromList [("cafe", 4.5), ("books", 18.0)]

stock : Map String Int
stock = M.fromList [("cafe", 3), ("books", 0)]

lineTotal : String -> Option Float
lineTotal name = match get name prices
  None => None
  Some p => match get name stock
    None => None
    Some n => Some (p * fromInt n)

main =
  println (lineTotal "cafe")
  println (lineTotal "tea")
```

```medaka-expect
Some 13.5
None
```

Two lookups, four lines of `match`, and the part that matters, `p * fromInt n`, is at
the bottom of a staircase. A third lookup makes it worse.

## The same thing with `do`

```medaka
import map.{Map, get}
import map as M

prices : Map String Float
prices = M.fromList [("cafe", 4.5), ("books", 18.0)]

stock : Map String Int
stock = M.fromList [("cafe", 3), ("books", 0)]

lineTotal : String -> Option Float
lineTotal name = do
  p <- get name prices
  n <- get name stock
  pure (p * fromInt n)

main =
  println (lineTotal "cafe")
  println (lineTotal "tea")
```

```medaka-expect
Some 13.5
None
```

Same output, no staircase. Three pieces of syntax do the work:

- **`do`** opens the block. Its statements are chained rather than merely run in
  order.
- **`<-`** binds through the context. `p <- get name prices` means: if the lookup
  produced `Some p`, continue with `p` in scope; if it produced `None`, stop here and
  make the whole block's value `None`. You never write the failing branch.
- **`pure`** goes the other way, wrapping an ordinary value back into the context.
  `p * fromInt n` is a `Float`; `pure (p * fromInt n)` is an `Option Float`, which
  is what `lineTotal` returns.

A `do` block can also contain plain `let` bindings for values that need no context.

> ⚠️ **A `do` block has to end in an expression, not a `let`.** The last statement is
> the block's value, and a `let` is not a value. The type checker currently accepts a
> block that ends in `let`, and the program then fails at run time with an unhelpful
> message, so this is one to catch by eye: if the last line of a `do` block starts
> with `let`, the `pure …` is missing.

## `Result`, and the running example

`Option` says "no value". `Result e a` says "no value, and here is why". It chains
under `do` the same way, carrying the first `Err` out of the block.

Parsing a ledger line is a chain of steps that can fail: split it, read four fields,
turn one into a number and another into a `Category`. Any step can fail, and the
caller wants to know which one did.

```medaka
import string.{split, trim, toFloat}
import list.{get}

data Category = Food | Housing | Books deriving (Debug)

data Expense =
  | { date : String, payee : String, amount : Float, category : Category }

impl Display Category where
  display Food = "food"
  display Housing = "housing"
  display Books = "books"

impl Display Expense where
  display e = "\{e.date}  \{e.payee}  $\{e.amount}  (\{e.category})"

field : Int -> List String -> Result String String
field i parts = match get i parts
  Some s => Ok (trim s)
  None => Err "missing field \{i}"

amountOf : String -> Result String Float
amountOf s = match toFloat s
  Some f => Ok f
  None => Err "not a number: \{s}"

categoryOf : String -> Result String Category
categoryOf "food" = Ok Food
categoryOf "housing" = Ok Housing
categoryOf "books" = Ok Books
categoryOf other = Err "unknown category: \{other}"

parseExpense : String -> Result String Expense
parseExpense line = do
  let parts = split "," line
  date <- field 0 parts
  payee <- field 1 parts
  raw <- field 2 parts
  amount <- amountOf raw
  catName <- field 3 parts
  category <- categoryOf catName
  pure
    Expense { date = date, payee = payee, amount = amount, category = category }

report : String -> <IO> Unit
report line = match parseExpense line
  Ok e => println e
  Err m => println "skipped: \{m}"

main =
  report "2026-08-01, Cafe Fish, 4.50, food"
  report "2026-08-02, Landlord, lots, housing"
  report "2026-08-03, Bookshop, 18.0"
```

```medaka-expect
2026-08-01  Cafe Fish  $4.5  (food)
skipped: not a number: lots
skipped: missing field 3
```

`parseExpense` reads as six plain steps. There are six places it can fail, one per
`<-`, and none of them is written out. Each `<-` is a point where the block can stop
and hand the failing step's `Err` to the caller. The second and third lines of output
are two different steps failing.

Note where the seam is. `parseExpense` is pure and returns a `Result`. `report` is
the `<IO>` function that decides what to do with it. Keeping the chain pure and the
decision at the edge is the normal arrangement, and it is why chapter 7's file
reading and this chapter's parsing fit together without either knowing about the
other.

## `do` works for any `Thenable`

`do` is not built into `Option` or `Result`. It is sugar over two interface methods,
`andThen` from `Thenable` and `pure` from `Applicative`, so a function written with
`do` and a `Thenable` constraint works for every type that implements them:

```medaka
both : Thenable m => m Int -> m Int -> m Int
both ma mb = do
  a <- ma
  b <- mb
  pure (a + b)

main =
  println (both (Some 1) (Some 2))
  println (both (None : Option Int) (Some 2))
  println (both (Ok 1 : Result String Int) (Err "boom"))
  println (both [1, 2] [10, 20])
```

```medaka-expect
Some 3
None
Err boom
[11, 21, 12, 22]
```

One function, four behaviors. The fourth shows that `do` is not only about failure.
`List` is a `Thenable` too, and its `andThen` tries every combination, so
`both [1, 2] [10, 20]` produces all four sums. "Chain in a context" is the general
idea. "Stop at the first failure" is what the context happens to do for `Option` and
`Result`.

In the prelude, `Option`, `Result e`, and `List` implement `Thenable`, which
requires `Applicative`, which requires `Mappable`. Writing your own, for a parser or
a state threader, is an ordinary `impl` in the style of chapter 5. The laws such an
implementation should satisfy are beyond this guide. The practical rule is that `do`
behaves the way you expect as long as your `andThen` does nothing but sequence.

> **Coming from Haskell?** `andThen` is `>>=` with the arguments swapped so the value
> comes first, `pure` is `pure`, and `Thenable` is `Monad` without the
> `Functor`/`Applicative`/`Monad` names. There is no `IO` instance, on purpose. IO is
> chapter 7's plain block.

---

That completes the language. The last two chapters cover how to organize more than
one file of it, and the tools that check, format, and test what you write.
