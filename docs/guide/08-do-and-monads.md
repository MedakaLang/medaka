# `do` and Monads

[Chapter 7](07-effects-and-io.md) made the negative case: `do` is not how you write
IO. This chapter makes the positive one. `do` is sugar for chaining computations that
carry a *context* — a value that might be missing, a value that might be an error, a
computation with several possible answers — so that the chaining code reads like
ordinary sequential code and the context handling disappears.

No `do` block in this chapter performs IO. Where an example prints, the printing is
an ordinary bare block in `main`, outside the chain.

## The problem `do` solves

Three lookups, each of which can fail. Written by hand, the plumbing is the program:

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

Two lookups, four lines of `match`, and the interesting part — `p * fromInt n` — is
buried at the bottom of a staircase. Add a third lookup and it gets worse.

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

Identical output, and the staircase is gone. Three pieces of syntax do the work:

- **`do`** opens the block, and the block's statements are chained rather than merely
  sequenced.
- **`<-`** *binds through* the context. `p <- get name prices` means "if the lookup
  produced `Some p`, carry on with `p` bound; if it produced `None`, abandon the whole
  block and let its value be `None`." The short-circuit is the point — you never write
  the failing branch.
- **`pure`** goes the other way, lifting an ordinary value back into the context.
  `p * fromInt n` is a `Float`; `pure (p * fromInt n)` is an `Option Float`, which is
  what `lineTotal` must return.

A `do` block may also contain plain `let` bindings for values that need no context,
and they read exactly as they do anywhere else.

> ⚠️ **A `do` block must end in an expression, not a `let`.** The last statement is
> the block's value, and a `let` is a binding rather than a value. Ending on one is
> currently accepted by the type checker and fails at run time with an unhelpful
> error, so the mistake is worth recognising by eye: if the last line of a `do` block
> starts with `let`, add the `pure …` you meant to write.

## `Result`, and the running example

`Option` says "no value". `Result e a` says "no value, and here is why" — and it
chains under `do` in exactly the same way, carrying the first `Err` out of the block.

Parsing a ledger line is a chain of fallible steps: split it, read four fields, turn
one into a number and another into a `Category`. Any of them can fail, and the caller
wants to know which.

```medaka
import string.{split, trim, toFloat}
import list.{get}

data Category = Food | Housing | Books deriving (Debug)

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

impl Display Expense where
  display e = "\{e.date}  \{e.payee}  $\{e.amount}  (\{e.category})"

field : Int -> List String -> Result String String
field i parts = match get i parts
  Some s => Ok (trim s)
  None   => Err "missing field \{i}"

amountOf : String -> Result String Float
amountOf s = match toFloat s
  Some f => Ok f
  None   => Err "not a number: \{s}"

categoryOf : String -> Result String Category
categoryOf "food"    = Ok Food
categoryOf "housing" = Ok Housing
categoryOf "books"   = Ok Books
categoryOf other     = Err "unknown category: \{other}"

parseExpense : String -> Result String Expense
parseExpense line = do
  let parts = split "," line
  date     <- field 0 parts
  payee    <- field 1 parts
  raw      <- field 2 parts
  amount   <- amountOf raw
  catName  <- field 3 parts
  category <- categoryOf catName
  pure (Expense { date = date, payee = payee, amount = amount, category = category })

report : String -> <IO> Unit
report line = match parseExpense line
  Ok e  => println e
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

`parseExpense` reads top to bottom as six ordinary steps. The failure paths are not
written anywhere, and there are five of them: each `<-` is a place the block can stop
and hand its `Err` to the caller, with the message the failing step produced. The
second and third lines of output are two different steps failing.

Note the shape of the seam. `parseExpense` is pure and returns a `Result`; `report`
is the `<IO>` function that decides what to do about it. Keeping the chain pure and
the decision at the edge is the normal arrangement, and it is why chapter 7's file
reading and this chapter's parsing compose without either one knowing about the
other.

## `do` abstracts over any monad

`do` is not built into `Option` or `Result`. It is sugar over two interface methods —
`andThen` from `Thenable` and `pure` from `Applicative` — so a function written with
`do` and a `Thenable` constraint works for *every* type that implements them:

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

One function, four behaviours, and the fourth is the one that shows `do` is not
secretly about failure. `List` is a `Thenable` too, and its `andThen` tries every
combination, so `both [1, 2] [10, 20]` produces all four sums rather than
short-circuiting. "Chain in a context" is the abstraction; "stop at the first
failure" is just what the context happens to do for `Option` and `Result`.

> **Coming from Haskell?** `andThen` is `>>=` with the arguments swapped so the value
> reads first, `pure` is `pure`, and `Thenable` is `Monad` without the historical
> `Functor`/`Applicative`/`Monad` naming. There is no `IO` instance, deliberately —
> that is [chapter 7](07-effects-and-io.md)'s bare block, not this.

## Which types work with `do`

Anything implementing `Thenable`, which requires `Applicative`, which requires
`Mappable`. In the prelude that is `Option`, `Result e`, and `List`; `map`,
`filterMap`, `fold` and friends from [chapter 6](06-working-with-data.md) come from
the same family of interfaces.

Writing your own `Thenable` — a parser, a writer that accumulates a log, a state
threader — is a real thing to do and follows the pattern of any other `impl` from
[chapter 5](05-interfaces.md). The laws such an implementation should satisfy, and
the reasons they matter, are beyond this guide; the practical rule is that `do` will
behave the way you expect if your `andThen` does nothing but sequence.

---

That closes the language. What remains is how to organise more than one file of it —
`import`, `export`, and project layout — and the tools that check, format, and test
what you have written.
