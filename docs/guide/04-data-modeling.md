# Data Modeling

This is the chapter that changes how you write programs. In Medaka you describe the
shape of your domain first, as a type, and the compiler then holds you to it: every
place that takes the value apart has to account for every shape it could have. Types
are not documentation you attach to code that already works — they are the thing you
write down before the code, and the reason the code ends up short.

Everything here is built out of one declaration form, `data`, in two flavours: a
choice between alternatives, and a bundle of named fields. Real types are usually both.

## Sum types: a choice between alternatives

A `data` declaration lists the constructors of a type, separated by `|`. Each is a
distinct way of *being* that type, and the value carries which one it is.

```medaka
data Category = Food | Housing | Books | Other

favourite : Category
favourite = Books
```

There is nothing else to a plain enumeration: `Food` is a value of type `Category`,
and `Category` has exactly four values. Constructors are capitalised, and they are
the only things you can pattern-match against.

Constructors carry payloads by listing the types they hold, and a longer declaration
is conventionally written one alternative per line:

```medaka
data Expense =
  | Coffee Float
  | Rent Float
  | Book String Float

cost : Expense -> Float
cost (Coffee c) = c
cost (Rent r)   = r
cost (Book _ p) = p

main = println (cost (Book "SICP" 35.0))
```

```medaka-expect
35.0
```

`Coffee` is now a *function* of type `Float -> Expense`, and `Book` of type
`String -> Float -> Expense`. Constructors are ordinary functions that happen to be
the only way to build the type.

A `data` declaration can take type parameters, written lowercase after the type name.
That is all it takes to define your own generic container:

```medaka
data Tree a
  = Leaf
  | Node (Tree a) a (Tree a)

insert : Ord a => a -> Tree a -> Tree a
insert v Leaf = Node Leaf v Leaf
insert v (Node l x r) = match compare v x
  Lt => Node (insert v l) x r
  Gt => Node l x (insert v r)
  Eq => Node l x r

toList : Tree a -> List a
toList Leaf = []
toList (Node l x r) = toList l ++ [x] ++ toList r

main =
  let t = fold (acc v => insert v acc) Leaf [5, 2, 8, 2, 9]
  println (toList t)
```

```medaka-expect
[2, 5, 8, 9]
```

`Ord a =>` in that signature is a *constraint*: `insert` works for any `a` that can
be ordered. [Chapter 5](05-interfaces.md) is about where those constraints come
from.

The stdlib's `Option` and `List` are exactly this shape and nothing more —
`Option a = Some a | None`, and a list is a chain of cons cells. There is no
privileged built-in data kind hiding behind them.

## Records: a bundle of named fields

When a value is one thing with several parts rather than a choice between
alternatives, give the fields names. A record is a `data` type with a single
brace-delimited constructor; because the constructor name would just repeat the type
name, you may leave it out and it is supplied for you.

```medaka
data Point = { x : Int, y : Int }
-- exactly equivalent to:
data Point2 = Point2 { x : Int, y : Int }

origin : Point
origin = Point { x = 0, y = 0 }

main = println origin.x
```

```medaka-expect
0
```

Note that there is no `record` keyword — the word `record` is an ordinary identifier
in Medaka and you are free to use it as a variable, a field, or a module name.

Here is the guide's running example, finally written properly. An expense has a date,
a payee, an amount, and a category, and the category is the sum type from the top of
the chapter:

```medaka
data Category = Food | Housing | Books | Other deriving (Eq, Debug)

data Expense =
  { date     : String
  , payee    : String
  , amount   : Float
  , category : Category
  }
  deriving (Eq, Debug)

coffee : Expense
coffee =
  Expense { date = "2026-08-31", payee = "Cafe Fish", amount = 4.50, category = Food }

main =
  println coffee.payee
  println (debug coffee.category)
  println (debug coffee)
```

```medaka-expect
Cafe Fish
Food
Expense { date = "2026-08-31", payee = "Cafe Fish", amount = 4.5, category = Food }
```

Construction requires every field; there are no defaults and no partially built
records. Field access is `.`, and when a variable in scope already has the field's
name, the *pun* shorthand lets you drop the `= name` half:

```medaka
data Expense = { payee : String, amount : Float }

fromParts : String -> Float -> Expense
fromParts payee amount = Expense { payee, amount }

main = println (fromParts "Landlord" 1200.0).payee
```

```medaka-expect
Landlord
```

> ⚠️ **`deriving` on its own line needs a multi-line `data` declaration.** After a
> one-line declaration it has to stay inline — `data Category = Food | Housing
> deriving (Eq)`. On its own line after a one-line declaration it is a parse error
> that blames the indentation rather than `deriving` itself, which is confusing the
> first time:
>
> ```
> error: deriv.mdk:2:2: unexpected `deriving`. Indentation (column 2) doesn't match
> the enclosing block
> ```

## Pattern matching is the eliminator

Constructors build values; patterns take them apart. That is the whole story — there
are no accessor functions generated for sum types, no `isCoffee` predicates, no
downcasts. If you have an `Expense` and want what is inside it, you match.

You have already seen patterns in clause heads. `match` is the expression form, and
the two are interchangeable:

```medaka
data Category = Food | Housing | Books | Other

data Expense = { payee : String, amount : Float, category : Category }

rate : Category -> Float
rate c = match c
  Housing => 0.0
  Books   => 0.5
  _       => 1.0

tag : Expense -> String
tag (Expense { category = Housing, amount }) = "rent of \{amount}"
tag (Expense { payee, amount })              = "\{payee} charged \{amount}"

main =
  println (rate Books)
  println (tag (Expense { payee = "Landlord", amount = 1200.0, category = Housing }))
  println (tag (Expense { payee = "Cafe Fish", amount = 4.5, category = Food }))
```

```medaka-expect
0.5
rent of 1200.0
Cafe Fish charged 4.5
```

Record patterns are worth dwelling on. `Expense { category = Housing, amount }`
matches *and* binds in one move: it fires only when the category is `Housing`, and
it brings `amount` into scope by punning. Fields you do not mention are ignored, and
`Expense { ... }` matches any expense while binding nothing.

The other pattern shapes you will reach for: `_` discards, `x :: rest` splits a list
into head and tail, `[]` matches the empty list, `(a, b)` destructures a tuple,
`whole@(Some x)` binds the whole value *and* its parts, and literal patterns like
`0` or `'a'..='z'` match by value.

## Exhaustiveness: the payoff

Here is what all of this buys. When you match on a sum type and forget a case, the
compiler tells you which one:

```medaka
data Shape
  = Circle Float
  | Rect Float Float
  | Triangle Float Float

area : Shape -> Float
area s = match s
  Circle r => 3.14159 * r * r
  Rect w h => w * h

main = println (area (Triangle 3.0 4.0))
```

Checking that program reports:

```
warning: shape.mdk:9:14: non-exhaustive match of 'Shape'. Missing case:
'Triangle _ _'; add a 'Triangle _ _ => …' arm, or a '_' wildcard arm to catch
the rest.
```

The diagnostic names the missing constructor, not merely "some case is missing".
This is the mechanism behind the usual claim that adding a variant to a type is
safe: add `Triangle` to `Shape` and every incomplete match in the program is
reported, one by one, with the case it now needs.

> ⚠️ **A non-exhaustive match is a *warning*, and `medaka check` still exits 0.**
> It becomes a real failure only when the missing case is actually reached, at
> which point the program stops:
>
> ```
> ./shape.mdk:7:15: runtime error [E-NONEXHAUSTIVE-MATCH]: non-exhaustive match
> ```
>
> So do not treat a green `check` as proof that your matches are complete — read
> the warnings. Reaching for a `_` wildcard arm silences the warning permanently,
> which is exactly what you do *not* want on a type you expect to grow.

## `Option` and `Result` instead of null and exceptions

Medaka has no null and no `undefined`. A value that might be absent says so in its
type, using `Option`:

```medaka-nocheck: stdlib declarations, shown for reference
data Option a = Some a | None
data Result e a = Ok a | Err e
```

The consequence is that you cannot forget to handle the absent case — it is a
constructor, so the exhaustiveness checker is watching. `Result` is the same idea
for operations that can fail with an explanation: note the parameter order, error
type first, so `Result String Expense` is "an `Expense`, or a `String` saying why
not".

```medaka
data Expense = { payee : String, amount : Float }

ledger : List Expense
ledger =
  [ Expense { payee = "Cafe Fish", amount = 4.50 }
  , Expense { payee = "Landlord", amount = 1200.0 }
  ]

findPayee : String -> List Expense -> Option Expense
findPayee _ [] = None
findPayee who (e :: rest) =
  if e.payee == who then Some e else findPayee who rest

report : Option Expense -> String
report None     = "no such payee"
report (Some e) = "\{e.payee}: \{e.amount}"

validate : Expense -> Result String Expense
validate e
  | e.amount <= 0.0 = Err "amount must be positive"
  | e.payee == ""   = Err "payee is required"
  | otherwise       = Ok e

main =
  println (report (findPayee "Landlord" ledger))
  println (report (findPayee "Nobody" ledger))
  println (report (map (e => { e | amount = 0.0 }) (findPayee "Cafe Fish" ledger)))
```

```medaka-expect
Landlord: 1200.0
no such payee
Cafe Fish: 0.0
```

That last line is a preview of chapter 6: `Option` is mappable, so you can transform
the value inside without unwrapping it. Chapter 8 goes further and shows how to chain
several fallible steps with `do` — but the shape you have now, match and handle, is
what most code actually does.

## `deriving`: the boilerplate you don't write

Comparing two expenses for equality, printing one for a log, sorting a list of them —
these are mechanical, and `deriving` writes them from the type's own structure.

```medaka
data Category = Food | Housing | Books | Other deriving (Eq, Ord, Debug)

data Expense =
  { payee    : String
  , amount   : Float
  , category : Category
  }
  deriving (Eq, Debug)

main =
  let a = Expense { payee = "Cafe Fish", amount = 4.5, category = Food }
  let b = { a | amount = 5.25 }
  println (a == b)
  println (a == a)
  println (lt Food Housing)
  println (debug b)
```

```medaka-expect
False
True
True
Expense { payee = "Cafe Fish", amount = 5.25, category = Food }
```

Six interfaces can be derived — `Eq`, `Ord`, `Debug`, `Display`, `Generic`, and
`Hashable` — and asking for anything else is an error that lists them:

```
error: d1.mdk:1:25: cannot derive 'Banana' for 'C'; supported: Eq, Ord, Debug,
Display, Generic, Hashable
```

`Ord` derives a comparison from constructor order, so `Food < Housing` above holds
because `Food` is declared first. [Chapter 5](05-interfaces.md) explains what
`deriving` is actually
generating and when you should write the implementation by hand instead.

## Functional update

Records are immutable, so "changing a field" means building a new record that differs
in that field. `{ record | field = value }` does it without restating the fields you
are keeping, and it nests:

```medaka
data Address = { city : String, street : String }

data Merchant = { name : String, address : Address }

main =
  let m = Merchant
    { name = "Cafe Fish"
    , address = Address { city = "Portland", street = "Ash" }
    }
  let moved = { m | address.city = "Seattle" }
  println moved.address.city
  println m.address.city
```

```medaka-expect
Seattle
Portland
```

`m` is untouched, as it must be — nothing in Medaka mutates a record in place, and
the original binding still names the original value. When a type has several
constructors, the variant form `Pt { p | y = 9 }` names which one you expect, and `p`
must be that variant.

## A note on `newtype`

`newtype` declares a type with exactly one constructor wrapping exactly one value. It
exists to make two things that are both "a `String` underneath" into two *different*
types the compiler will not let you confuse:

```medaka
newtype Payee = Payee String deriving (Eq, Debug)

newtype Note = Note String deriving (Eq, Debug)

main =
  println (Payee "Landlord" == Payee "Landlord")
  println (debug (Note "reimbursed"))
```

```medaka-expect
True
Note "reimbursed"
```

Reach for it whenever a domain concept is currently being passed around as a bare
`String` or `Int` and confusing it with another one would be a real bug.

---

You can now describe a domain and take it apart safely. What is still missing is
behavior that varies by type — `debug` and `==` worked above because something
implemented them for your types. [Chapter 5](05-interfaces.md) is about writing those
implementations yourself.
