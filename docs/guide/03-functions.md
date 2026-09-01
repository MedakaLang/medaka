# Functions

Functions are how behavior is packaged in Medaka, and there is only one way to make
one: bind a name to something that takes arguments. There is no `function` keyword,
no `def`, no `fun`. This chapter covers defining functions, splitting them into
clauses that match on their arguments, guarding those clauses with conditions, and
gluing small functions together into bigger ones.

## Defining a function

A definition is a name, its parameters, `=`, and a body. A signature on the line
above is optional but recommended.

```medaka
double : Int -> Int
double x = x + x

area : Float -> Float -> Float
area w h = w * h

main = println (double (area 3.0 4.0 |> floatToInt))
```

```medaka-expect
24
```

Application is by juxtaposition — `area 3.0 4.0`, not `area(3.0, 4.0)` — and it binds
tighter than any operator, which is why `double (area 3.0 4.0 …)` needs its
parentheses.

Functions are recursive without saying so, and mutually recursive at the top level
without a forward declaration:

```medaka
isEven : Int -> Bool
isEven 0 = True
isEven n = isOdd (n - 1)

isOdd : Int -> Bool
isOdd 0 = False
isOdd n = isEven (n - 1)

main = println (isEven 10)
```

```medaka-expect
True
```

## Several clauses, one function

That last example is already doing the thing that makes Medaka code read the way it
does: a function is written as a *stack of clauses*, each with patterns in the head,
tried top to bottom. This is the preferred way to take a data type apart.

Here is `cost` from the introduction, in full:

```medaka
data Expense = Coffee Float | Rent Float | Book String Float

cost : Expense -> Float
cost (Coffee c) = c
cost (Rent r) = r
cost (Book _ p) = p

main =
  println (cost (Coffee 4.5))
  println (cost (Book "SICP" 35.0))
```

```medaka-expect
4.5
35.0
```

All three clauses belong to one function named `cost`; they must be adjacent and
carry the same number of parameters. `_` in the `Book` clause is a wildcard — the
title is matched and discarded, and naming it would only invite the linter to point
out that nothing uses it. [Chapter 4](04-data-modeling.md) covers patterns themselves
in depth; here the point is only that the *head* of a clause is a pattern position.

## Guards

A clause can be split further by conditions. An equation guard is a leading `|`,
each with its own body, tried in order; `otherwise` is the conventional catch-all.

```medaka
band : Float -> String
band amount
  | amount < budget / 10.0 = "small"
  | amount < budget = "medium"
  | otherwise = "large"
  where
    budget = 100.0

main =
  println (band 4.5)
  println (band 35.0)
  println (band 1200.0)
```

```medaka-expect
small
medium
large
```

If no guard on a clause holds, control falls through to the *next clause*, so guards
and multiple clauses compose rather than competing. A single guard can also sit
inline on the clause head: `drop n xs | n <= 0 = xs`.

> ⚠️ **An equation guard is `|`; a match-arm guard is `if`.** The two spellings are
> not interchangeable, and using the wrong one is a parse error rather than a
> subtle misbehavior. Inside `match`, write `pat if cond => body`:
>
> ```
> error: guards.mdk:2:4: a match-arm guard uses `if`, not `|` — write `pat if cond
> => body` (Medaka has no or-patterns)
> ```

## `where`

`where` attaches local definitions to a function. They are visible in the body and,
as in `band` above, across *all* the guards of the clause when the `where` sits at
the guards' indentation. Locals may be functions with their own clauses:

```medaka
report : Float -> String
report amount = "\{amount} is \{label (amount > 100.0)}"
  where
    label True = "a lot"
    label False = "fine"

main = println (report 4.5)
```

```medaka-expect
4.5 is fine
```

`where` can also trail the body line — `f x = g x where` followed by an indented
block. Both spellings parse, but they are not two styles the formatter respects:
`medaka fmt --write` normalizes the trailing form to the one above, moving `where`
onto its own line and indenting the block under it. Write whichever you like and
let `fmt` settle it.

## Lambdas

An anonymous function is `params => body`. There is no backslash and no `fun`
keyword, and the parameters are simply listed before a single arrow.

```medaka
main =
  let addTwo = a b => a + b
  let squareAll = map (n => n * n)
  println (addTwo 3 4)
  println (squareAll [1, 2, 3])
```

```medaka-expect
7
[1, 4, 9]
```

A parameter position is a pattern, so a lambda can destructure directly:
`(Some x) => x`, `xs@rest => xs`, `_ => 0`.

> ⚠️ **`(x, y) => …` takes one tuple, not two arguments.** Parentheses around a
> lambda's parameters are a *tuple pattern*, not an argument list — the habit is
> easy to bring from JavaScript or Rust and the resulting type error points at the
> call site rather than the lambda. Two parameters are written with a space
> between them.

```medaka
addPair : (Int, Int) -> Int
addPair (x, y) = x + y

main =
  let addTwo = a b => a + b
  println (addTwo 3 4)
  println (addPair (3, 4))
```

```medaka-expect
7
7
```

## Piping, composing, and sections

Three small pieces of syntax do most of the work of keeping call chains flat.

`|>` applies a value to a function, left to right, so a transformation reads in the
order it happens. `>>` composes two functions left to right and `<<` right to left,
producing a new function without naming its argument. And a *section* is a
parenthesized operator with one side filled in: `(+ 5)` is `x => x + 5`, `(2 * _)`
is `x => 2 * x` — the `_` marks the missing operand when it is the right-hand one —
and a bare `(+)` or `(==)` is the operator itself as an ordinary function.

```medaka
data Expense = Coffee Float | Rent Float | Book String Float

cost : Expense -> Float
cost (Coffee c) = c
cost (Rent r) = r
cost (Book _ p) = p

isBig : Float -> Bool
isBig = (> 100.0)

verdict : Expense -> String
verdict = cost >> isBig >> label
  where
    label True = "a big one"
    label False = "pocket change"

main =
  let expenses = [Coffee 4.5, Rent 1200.0, Book "SICP" 35.0]
  println (expenses |> map cost |> fold (+) 0.0)
  println (expenses |> map cost |> filter (> 100.0))
  println (verdict (Coffee 4.5))
  println (verdict (Rent 1200.0))
```

```medaka-expect
1239.5
[1200.0]
pocket change
a big one
```

`verdict` never mentions the expense it is given. That is worth doing when the
pipeline *is* the explanation, as here, and worth abandoning the moment a reader
has to run the composition in their head to see what the argument was.

## A lambda that immediately matches

`match` is an expression, so it can be a lambda's whole body. `x => match x` is the
idiom for "a function defined by cases" in a position where a name would be noise —
passed to `map`, say.

```medaka
main = println (map
  (x => match x
    Some n if n > 100 => "a big \{n}"
    Some n => "just \{n}"
    None => "nothing")
  [Some 5, Some 500, None])
```

```medaka-expect
[just 5, a big 500, nothing]
```

Note the `if` guards on the arms — the match-arm spelling from the callout above.
Arms are tried top to bottom, so the specific `Some n if n > 100` has to come before
the general `Some n` or it would never fire.

You now have every way Medaka gives you to define behavior. The next chapter is
about the other half: [describing the data](04-data-modeling.md) that behavior takes
apart.
