# Data Modeling

In Medaka you describe the shape of your data first, as a type, and the compiler holds
the rest of the program to that description. Every place that takes a value apart has
to account for every shape the value can have. This chapter is about the one
declaration that does all of it, `data`, in its two forms: a choice between
alternatives, and a bundle of named fields.

## Sum types: one of several alternatives

A `data` declaration lists the constructors of a type, separated by `|`. A value of
the type is exactly one of them.

```medaka
data Category = Food | Housing | Books | Other

favorite : Category
favorite = Books
```

That is a complete definition. `Category` has four values, and `Food` is one of them.
Constructor names are capitalized, and constructors are the only things you can
pattern match against.

A constructor can carry data. List the types of its fields after its name:

```medaka
data Expense = Coffee Float | Rent Float | Book String Float

cost : Expense -> Float
cost (Coffee c) = c
cost (Rent r) = r
cost (Book _ p) = p

main = println (cost (Book "SICP" 35.0))
```

```medaka-expect
35.0
```

`Coffee` is now a function of type `Float -> Expense`, and `Book` has type
`String -> Float -> Expense`. Constructors are ordinary functions, and they are the
only way to build a value of the type.

A `data` declaration can take type parameters, written in lowercase after the type
name. That is all it takes to define a generic container:

```medaka
data Tree a = Leaf | Node (Tree a) a (Tree a)

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

The `Ord a =>` in `insert`'s signature is a constraint: `insert` works for any `a`
that can be compared. Chapter 5 explains where constraints come from.

The standard library's `Option` and `Result` are declared this same way, in
[`stdlib/core.mdk`](../../stdlib/core.mdk):

```medaka-nocheck: stdlib declarations, shown for reference
data Option a = Some a | None
data Result e a = Ok a | Err e
```

Nothing about them is built in. A sum type you write has the same standing as one
from the standard library. `List` is the exception: it is a compiler builtin with its
own literal syntax and the `::` operator, but it behaves like the two-constructor
type it looks like.

## Records: a bundle of named fields

When a value is one thing with several parts, give the parts names. A record is a
`data` type with a single constructor whose fields are written in braces. The
constructor is usually named after the type, so you can leave its name out and the
compiler fills it in.

```medaka
data Point = { x : Int, y : Int }
-- the same as:
data Point2 = Point2 { x : Int, y : Int }

origin : Point
origin = Point { x = 0, y = 0 }

main = println origin.x
```

```medaka-expect
0
```

There is no `record` keyword. `record` is an ordinary word you can use as a variable
name.

Here is the running example as a proper record. An expense has a date, a payee, an
amount, and a category, and the category is the sum type from the top of the
chapter:

```medaka
data Category = Food | Housing | Books | Other deriving (Eq, Debug)

data Expense =
  | { date : String, payee : String, amount : Float, category : Category }
deriving (Eq, Debug)

coffee : Expense
coffee = Expense {
  date = "2026-08-31",
  payee = "Cafe Fish",
  amount = 4.5,
  category = Food,
}

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

Building a record requires every field. There are no defaults and no partially built
records. Fields are read with `.`. When a variable in scope already has the same name
as a field, you can write the field name alone and skip the `= name` part:

```medaka
data Expense = { payee : String, amount : Float }

fromParts : String -> Float -> Expense
fromParts payee amount = Expense { payee, amount }

main = println (fromParts "Landlord" 1200.0).payee
```

```medaka-expect
Landlord
```

The `deriving (Eq, Debug)` clauses ask the compiler to generate equality and a
debug printer for the type. `deriving` gets its own section below. One thing to
know now is where it goes: after a one-line `data` declaration it has to stay on that
line, and it can only move to its own line when the declaration spans several lines,
as it does for `Expense` above.

> **Coming from Haskell?** Field names belong to their type, not to the module. Two
> record types in one file can both have an `amount` field, and `e.amount` reads the
> field directly rather than through a generated accessor function. The field pun
> (`Expense { payee, amount }`) is always on.

## Pattern matching takes values apart

Constructors build values and patterns take them apart. There are no generated
accessor functions for sum types, no `isCoffee` predicates, and no casts. To get at
what is inside an `Expense`, you match on it.

You have already seen patterns in clause heads. `match` is the expression form, and
the two do the same thing. When you are defining a function that matches on its
argument, use clauses. When you have a value in hand inside an expression, use
`match`.

```medaka
data Category = Food | Housing | Books | Other

data Expense = { payee : String, amount : Float, category : Category }

rate : Category -> Float
rate c = match c
  Housing => 0.0
  Books => 0.5
  _ => 1.0

tag : Expense -> String
tag (Expense { category = Housing, amount }) = "rent of \{amount}"
tag (Expense { payee, amount }) = "\{payee} charged \{amount}"

main =
  println (rate Books)
  println (tag
    Expense { payee = "Landlord", amount = 1200.0, category = Housing })
  println (tag Expense { payee = "Cafe Fish", amount = 4.5, category = Food })
```

```medaka-expect
0.5
rent of 1200.0
Cafe Fish charged 4.5
```

Record patterns do two jobs at once. `Expense { category = Housing, amount }` only
matches when the category is `Housing`, and it binds `amount` as a side effect of
matching. Fields you do not mention are ignored. `Expense { ... }` matches any expense
and binds nothing.

Other patterns you will use: `_` matches anything and binds nothing, `x :: rest`
splits a list into its first element and the remainder, `[]` matches the empty list,
`(a, b)` takes a tuple apart, `whole@(Some x)` binds both the whole value and its
parts, and a literal like `0` or a range like `'a'..='z'` matches by value.

## Exhaustiveness

When you match on a sum type and leave out a case, the compiler tells you which one:

```medaka
data Shape = Circle Float | Rect Float Float | Triangle Float Float

area : Shape -> Float
area s = match s
  Circle r => 3.14159 * r * r
  Rect w h => w * h

main = println (area (Triangle 3.0 4.0))
```

Checking that program reports:

```
warning: shape.mdk:6:14: non-exhaustive match of 'Shape'. Missing case:
'Triangle _ _'; add a 'Triangle _ _ => …' arm, or a '_' wildcard arm to catch
the rest.
```

This is what makes adding a constructor to a type safe. Add `Triangle` to `Shape`,
and every match in the program that does not handle it is reported, with the case it
now needs.

> ⚠️ **A non-exhaustive match is a warning, not an error.** `medaka check` still
> exits 0. The program fails only if the missing case is actually reached:
>
> ```
> ./shape.mdk:4:15: runtime error [E-NONEXHAUSTIVE-MATCH]: non-exhaustive match
> ```
>
> Read the warnings. And think twice before adding a `_` arm to silence one: a
> wildcard also silences the warning for every constructor you add later.

## `Option` and `Result` instead of null and exceptions

Medaka has no null. A value that might be absent says so in its type, using
`Option`, and because `None` is a constructor, the exhaustiveness check makes sure
you handle it. `Result` is the same idea for an operation that can fail with a
reason. Note the order of its parameters: the error type comes first, so
`Result String Expense` reads as "an `Expense`, or a `String` explaining why not".

```medaka
data Expense = { payee : String, amount : Float }

ledger : List Expense
ledger = [
  Expense { payee = "Cafe Fish", amount = 4.5 },
  Expense { payee = "Landlord", amount = 1200.0 },
]

findPayee : String -> List Expense -> Option Expense
findPayee _ [] = None
findPayee who (e::rest) = if e.payee == who then Some e else findPayee who rest

report : Option Expense -> String
report None = "no such payee"
report (Some e) = "\{e.payee}: \{e.amount}"

validate : Expense -> Result String Expense
validate e
  | e.amount <= 0.0 = Err "amount must be positive"
  | e.payee == "" = Err "payee is required"
  | otherwise = Ok e

main =
  println (report (findPayee "Landlord" ledger))
  println (report (findPayee "Nobody" ledger))
  println (report (map
    (e => { e | amount = 0.0 })
    (findPayee "Cafe Fish" ledger)))
```

```medaka-expect
Landlord: 1200.0
no such payee
Cafe Fish: 0.0
```

The last line uses `map` on an `Option`, which transforms the value inside without
unwrapping it. Chapter 6 covers that, and chapter 8 shows how to chain several steps
that each return an `Option` or `Result`. Most of the time, though, the code you
write looks like `report`: match, and handle both cases.

## `deriving`

Comparing two expenses for equality, printing one, or sorting a list of them is
mechanical work, and `deriving` writes it from the type's structure.

```medaka
data Category = Food | Housing | Books | Other deriving (Eq, Ord, Debug)

data Expense =
  | { payee : String, amount : Float, category : Category }
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

You can derive `Eq`, `Ord`, `Debug`, `Display`, `Generic`, and `Hashable`. Asking
for anything else is an error that lists those six. A derived `Ord` orders
constructors by their declaration order, which is why `Food` is less than `Housing`
above. Chapter 5 explains what `deriving` generates and when to write the
implementation by hand instead.

## Functional update

Records are immutable, so "changing a field" means building a new record that
differs in that field. `{ r | field = value }` does that without restating the fields
you are keeping, and it nests.

```medaka
data Address = { city : String, street : String }

data Merchant = { name : String, address : Address }

main =
  let m = Merchant {
    name = "Cafe Fish",
    address = Address { city = "Portland", street = "Ash" },
  }
  let moved = { m | address = { m.address | city = "Seattle" } }
  println moved.address.city
  println m.address.city
```

```medaka-expect
Seattle
Portland
```

`m` is unchanged, and still names the original value. When a type has several
constructors, write the constructor in front, `Pt { p | y = 9 }`, and `p` has to be
that constructor.

## `newtype`

`newtype` declares a type with one constructor wrapping one value. Use it when two
things are both a `String` or an `Int` underneath but must not be confused with each
other.

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

A `Payee` cannot be passed where a `Note` is expected, and the wrapper costs nothing
at run time.

---

You can now describe a domain and take it apart. `==` and `debug` worked in this
chapter because something implemented them for your types. [Chapter 5](05-interfaces.md)
is about writing those implementations yourself.
