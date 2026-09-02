# Interfaces

An `interface` names a set of operations. An `impl` says how one particular type
performs them. Between them, they let you write code that works for any type that
supports the operations you need, and the compiler picks the right implementation
for each call. If you know Haskell's typeclasses or Rust's traits, this is the same
idea. If not, think of an interface as a named capability that a type can have.

The `deriving (Eq, Debug)` in chapter 4 was this machinery with the implementation
written for you. This chapter is about writing it yourself.

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

`a` is the interface's parameter, the type being described. Every method's
signature has to mention it, because the argument's type is what the compiler uses
to choose an `impl`. Given a call `price (Ticket 12.5)`, the compiler sees a
`Ticket` and selects `impl Priced Ticket`.

A method body inside an `impl` is an ordinary function definition, so it can have
several clauses, patterns, and guards:

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

Interfaces pay off in generic code. A lowercase type variable in a signature means
"any type". A constraint in front of `=>` narrows it to "any type with this
interface", and inside the function you can use the interface's methods on it.

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

Several constraints go in parentheses, separated by commas, as in `expensive`. The
compiler infers constraints on its own, so you could leave the signatures off. Write
them anyway: they state what the function needs from its arguments, and you will read
them constantly in library signatures.

## The interfaces you meet every day

Five interfaces from the prelude cover most of what you will implement or require:

| Interface | Methods | Meaning |
|---|---|---|
| `Eq` | `eq` (`==`, `/=`) | values can be compared for equality |
| `Ord` | `compare`, `lt`, `gt`, `min`, `max`, … | values are ordered; requires `Eq` |
| `Debug` | `debug` | a developer-facing rendering that shows the structure |
| `Display` | `display` | a human-facing rendering |
| `Num` | `add`, `sub`, `mul`, `negate`, `fromInt`, … | the arithmetic operators; requires `Eq` |

`Debug` and `Display` are separate on purpose. `debug` is for you: it quotes strings
and shows constructor names, so you can see what a value is made of. `display` is
for the user, and it is what `println` and string interpolation call.

That is where the running example picks up. An `Expense` should look one way in a
report and another way in a debugging session:

```medaka
data Category = Food | Housing | Books | Other deriving (Debug)

data Expense = {
  date : String,
  payee : String,
  amount : Float,
  category : Category,
}
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

`println coffee` works because `println` requires `Display` and `Expense` now has
it. Inside that implementation, `\{e.category}` calls `display` on the category, so
the `Display Category` implementation is used too. Interpolation is `Display` all the
way down.

## Default methods

An interface can provide a body for a method. An `impl` that says nothing about the
method gets the default. An `impl` that defines it overrides the default.

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

A default method's signature still has to mention `a`, even if its body does not
use it. Without `a` in the type there is nothing to dispatch on, and the compiler
says so:

```
error: d2.mdk:4:13: Method 'currency' in interface 'Priced' does not mention
interface parameter(s) 'a'; cannot dispatch
```

## Conditional implementations: `impl … requires …`

An implementation can depend on another one. "A list of `a` has a price, provided
`a` has a price" is written with `requires`:

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

The second line works because the implementation applies to itself: a
`List (List Ticket)` has a price because `List Ticket` does. The prelude's
`impl Eq (List a) requires Eq a` has the same shape, and it is why `[1, 2] == [1, 2]`
works for every element type that has `Eq`.

## `requires` on an interface

`requires` can also go on the interface itself, where it means "to implement this,
you must implement that first". `Ord` requires `Eq` this way, since an ordering that
disagrees with equality would make no sense.

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

`invoiceLine` calls `price` without declaring a `Priced` constraint of its own.
Inside a `Billable` implementation, `Priced` is already known to hold.

## Overlapping implementations: the most specific one wins

Two implementations can both apply to the same type. When they do, Medaka picks the
more specific one, with no annotation and no ordering rule. `impl Render (List Expense)`
is more specific than `impl Render (List a)`, so a list of expenses gets the first and
a list of anything else gets the second:

```medaka
data Expense = { payee : String, amount : Float }

interface Render a where
  render : a -> String

impl Render Expense where
  render e = "\{e.payee} $\{e.amount}"

impl Render (List a) where
  render xs = "a list of \{length xs} thing(s)"

impl Render (List Expense) where
  render xs =
    "a ledger of \{length xs} expense(s), totaling $\{fold (acc e => acc + e.amount) 0.0 xs}"

main =
  println (render [True, False])
  println
    (render [
      Expense { payee = "Cafe Fish", amount = 4.5 },
      Expense { payee = "Landlord", amount = 1200.0 },
    ])
```

```medaka-expect
a list of 2 thing(s)
a ledger of 2 expense(s), totaling $1204.5
```

Both calls go through the same `render`, and the two lines of output come from the
two implementations. The `List Bool` call uses the general implementation even
though `Bool` has no `Render` of its own, because the general body never looks at an
element.

> **Coming from Haskell?** This is the part that differs. GHC treats overlapping
> instances as an error unless you opt in with a pragma. In Medaka, most-specific
> selection is the normal rule, so there is no `OVERLAPPING` pragma, no newtype
> wrapper to select an instance, and no named instances. A plain `impl` covers every
> case.

## Where `deriving` fits

`deriving (Eq, Ord, Debug, Display, Generic, Hashable)` on a `data` declaration
generates the implementations you would otherwise write, from the type's structure.
Derived `Eq` compares constructors and then fields. Derived `Ord` orders by
declaration position and then by fields. Derived `Debug` prints the constructor and
its fields.

Derive when the structural answer is the right one. Write the `impl` by hand when it
is not, which for `Display` is nearly always: how a value should look to a person is
a design decision, not a property of its fields. That is why `Expense` above derived
`Debug` and wrote `Display` by hand.

---

Next, [chapter 6](06-working-with-data.md) covers the containers you keep data in
and the `map`/`filter`/`fold` vocabulary that has been showing up in these examples
without an introduction.
