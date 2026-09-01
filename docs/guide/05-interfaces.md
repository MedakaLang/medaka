# Interfaces

An `interface` declares a set of operations; an `impl` says how a particular type
performs them. Together they give you behavior that varies by type without
inheritance, without runtime dispatch tables you maintain by hand, and without
losing type inference. If you have met Haskell's typeclasses or Rust's traits, this
is that idea; if you haven't, think of it as "a named capability a type can have".

[Chapter 4](04-data-modeling.md)'s `deriving (Eq, Debug)` was already this
machinery — it wrote the implementations for you. This chapter is about writing them
yourself.

## Declaring an interface

```medaka
interface Priced a where
  price : a -> Float

data Ticket = Ticket Float

impl Priced Ticket where
  price (Ticket p) = p

main = println (price (Ticket 12.5))
```

```medaka-expect
12.5
```

`a` is the interface's parameter — the type being described. Every method signature
must mention it, because that is what dispatch keys on: given a call to `price`, the
compiler looks at the argument's type and selects the matching `impl`.

An `impl` body is an ordinary function definition and takes the same shapes: several
clauses, patterns in the heads, guards.

```medaka
data Card = Silver | Gold | Platinum

interface Discount a where
  rate : a -> Float
  waived : a -> Bool

impl Discount Card where
  rate Silver = 0.05
  rate Gold = 0.1
  rate Platinum = 0.2
  waived c
    | rate c > 0.15 = True
    | otherwise = False

main =
  println (rate Gold)
  println (waived Platinum)
  println (waived Silver)
```

```medaka-expect
0.1
True
False
```

## Constraints: `=>` in a signature

An interface earns its keep in *generic* code. A lowercase type variable in a
signature means "any type"; a constraint before `=>` narrows it to "any type that
implements this interface", and inside the function you may use that interface's
methods.

```medaka
interface Priced a where
  price : a -> Float

data Ticket = Ticket Float

impl Priced Ticket where
  price (Ticket p) = p

total : Priced a => List a -> Float
total xs = fold (acc x => acc + price x) 0.0 xs

expensive : (Priced a, Display a) => a -> String
expensive x = "\{x} costs \{price x}"

impl Display Ticket where
  display (Ticket p) = "ticket(\{p})"

main =
  println (total [Ticket 1.0, Ticket 2.5])
  println (expensive (Ticket 12.5))
```

```medaka-expect
3.5
ticket(12.5) costs 12.5
```

Several constraints are written as a parenthesized, comma-separated list, as in
`expensive`. You will rarely write these by hand for your own code — inference works
them out — but you will read them constantly in stdlib signatures, and writing them
on your own top-level definitions documents exactly what a function needs.

## The working vocabulary

Five interfaces from the prelude account for most of what you will implement:

| Interface | Method(s) | What it means |
|---|---|---|
| `Eq` | `eq` (`==`, `/=`) | values can be compared for equality |
| `Ord` | `compare`, `lt`, `gt`, `min`, `max` | values are ordered; requires `Eq` |
| `Debug` | `debug` | a developer-facing, round-trippable rendering |
| `Display` | `display` | a human-facing rendering |
| `Num` | `add`, `sub`, `mul`, `negate`, `fromInt`, … | the arithmetic operators; requires `Eq` |

`Debug` and `Display` are deliberately two interfaces rather than one. `debug` is for
you — it quotes strings and shows constructors, so its output can be read back.
`display` is for your users, and it is what `println` and string interpolation call.

That distinction is where the running example picks up. An `Expense` should render
one way in a log line and another way in a stack trace:

```medaka
data Category = Food | Housing | Books | Other deriving (Debug)

data Expense =
  | { date : String, payee : String, amount : Float, category : Category }
deriving (Debug)

impl Display Category where
  display Food = "food"
  display Housing = "housing"
  display Books = "books"
  display Other = "other"

impl Display Expense where
  display e = "\{e.date}  \{e.payee}  $\{e.amount}  (\{e.category})"

main =
  let coffee = Expense {
    date = "2026-08-31",
    payee = "Cafe Fish",
    amount = 4.5,
    category = Food,
  }
  println coffee
  println (debug coffee)
```

```medaka-expect
2026-08-31  Cafe Fish  $4.5  (food)
Expense { date = "2026-08-31", payee = "Cafe Fish", amount = 4.5, category = Food }
```

Two things happen there that are worth naming. `println coffee` works because
`println` requires `Display` and we supplied it. And `\{e.category}` inside the
`Display Expense` body calls `display` on the category — string interpolation is
`Display`, all the way down, so implementing it once composes everywhere.

## Default methods

An interface may supply a body for a method. Implementations that say nothing about
that method inherit the default; implementations that define it override it.

```medaka
interface Priced a where
  price : a -> Float
  isFree : a -> Bool
  isFree x = price x == 0.0

data Ticket = Ticket Float
data Sample = Sample

impl Priced Ticket where
  price (Ticket p) = p

impl Priced Sample where
  price _ = 0.0
  isFree _ = True

main =
  println (isFree (Ticket 12.5))
  println (isFree Sample)
```

```medaka-expect
False
True
```

The default's *signature* still has to mention the interface parameter, even though
its body might not — without `a` in the type there is nothing to dispatch on, and
the compiler says so rather than picking arbitrarily:

```
error: d2.mdk:4:13: Method 'currency' in interface 'Priced' does not mention
interface parameter(s) 'a'; cannot dispatch
```

## Conditional implementations: `impl … requires …`

An implementation can itself depend on an interface. "A list of `a`s is priceable,
*provided* `a` is priceable" is written with `requires`:

```medaka
interface Priced a where
  price : a -> Float

data Ticket = Ticket Float

impl Priced Ticket where
  price (Ticket p) = p

impl Priced (List a) requires Priced a where
  price xs = fold (acc x => acc + price x) 0.0 xs

main =
  println (price [Ticket 1.0, Ticket 2.5])
  println (price [[Ticket 1.0], [Ticket 2.5, Ticket 4.0]])
```

```medaka-expect
3.5
7.5
```

The second line is the point: `List (List Ticket)` is priceable because
`List a requires Priced a` applies to itself, and the compiler assembles that chain
without being told to. `impl Eq (List a) requires Eq a` in the prelude is the same
shape, and is why `[1, 2] == [1, 2]` works for every element type that has `Eq`.

## `requires` on the interface itself

`requires` also appears on an `interface` declaration, where it means "you cannot
implement this one without implementing that one first". `Ord` requires `Eq` in
exactly this way — an ordering that disagreed with equality would be nonsense.

```medaka
interface Priced a where
  price : a -> Float

interface Billable a requires Priced a where
  invoiceLine : a -> String

data Ticket = Ticket Float

impl Priced Ticket where
  price (Ticket p) = p

impl Billable Ticket where
  invoiceLine t = "1 x ticket ... \{price t}"

main = println (invoiceLine (Ticket 3.0))
```

```medaka-expect
1 x ticket ... 3.0
```

Note that `invoiceLine`'s body calls `price` without a constraint of its own: inside
a `Billable` implementation, `Priced` is already known to hold. Constraints declared
on the interface propagate to everyone who uses it.

## When implementations overlap, the most specific one wins

This is the part that is genuinely not Haskell, so read it carefully.

Two implementations can both apply to the same type. When they do, Medaka picks the
*more specific* one automatically — no annotation, no ordering rule, no import
tricks. `impl Render (List Expense)` is more specific than `impl Render (List a)`,
so a list of expenses gets the former and a list of anything else gets the latter:

```medaka
data Expense = { payee : String, amount : Float }

interface Render a where
  render : a -> String

impl Render Expense where
  render e = "\{e.payee} $\{e.amount}"

impl Render (List a) where
  render xs = "a list of \{length xs} thing(s)"

impl Render (List Expense) where
  render xs = "a ledger of \{length xs} expense(s), totalling $\{fold (acc e => acc + e.amount) 0.0 xs}"

main =
  println (render [True, False])
  println (render
    [
      Expense { payee = "Cafe Fish", amount = 4.5 },
      Expense { payee = "Landlord", amount = 1200.0 },
    ])
```

```medaka-expect
a list of 2 thing(s)
a ledger of 2 expense(s), totalling $1204.5
```

Both calls go through the same `render`, on two values of the same shape — a list —
and the two lines of output are the two different implementations firing. The
`List Bool` call reaches the general implementation even though `Bool` has no
`Render` implementation at all, because the general body never looks at an element.

> **Coming from Haskell?** GHC has no most-specific-instance selection by default —
> two overlapping instances are a coherence error at the use site unless you opt in
> with `{-# OVERLAPPING #-}` or `{-# INCOHERENT #-}`, and even then the resolution
> is a pragma-driven exception rather than the normal rule. Medaka makes
> most-specific selection the normal rule instead, so there is no `OVERLAPPING`
> pragma to reach for, no `newtype`-wrapping ritual to pick an instance, and no
> named instances — the `impl Name of Iface Ty` form, `default impl`, and the
> `@Name` hint at a use site were all removed together, because most-specific
> selection makes them unnecessary. A plain `impl` covers every case.

## Where `deriving` fits

`deriving (Eq, Ord, Debug, Display, Generic, Hashable)` on a `data` declaration
generates exactly the implementations you would otherwise write, from the type's
structure: `Eq` compares constructors and then fields; `Ord` orders by declaration
position and then by field; `Debug` prints the constructor and its fields.

Derive when the structural answer is the right answer, and write the `impl` by hand
when it is not — which, for `Display`, is nearly always, since how a value should
look to a user is a design decision and not a property of its fields. `Expense`
above derived `Debug` and hand-wrote `Display` for exactly that reason.

---

You can now describe data and give it behavior.
[Chapter 6](06-working-with-data.md) turns to the collections
and combinators you will use to actually push that data around — `List` versus
`Array`, `Map` and `Set`, and the `map`/`filter`/`fold` vocabulary that has been
quietly appearing in these examples all along.
