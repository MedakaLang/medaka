# Functions

There is one way to define a function in Medaka: bind a name to something that takes
parameters. There is no `function`, `def`, or `fun` keyword. This chapter covers
defining functions, splitting them into clauses that match on their arguments, adding
conditions to those clauses, and combining small functions into bigger ones.

## Defining a function

A definition is a name, its parameters, `=`, and a body. The signature above it is
optional, but write one on anything top-level.

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

You call a function by writing its arguments after it, separated by spaces:
`area 3.0 4.0`, not `area(3.0, 4.0)`. Application binds tighter than any operator,
which is why the argument to `double` above needs parentheses.

Functions can call themselves, and top-level functions can call each other in any
order, with no forward declaration.

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

`isEven` above is written as two clauses. The first matches the argument `0`, the
second matches anything and names it `n`. Clauses are tried top to bottom, and the
first one whose patterns match runs. This is the usual way to take a data type apart.
Here is `cost` from the introduction:

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

The three clauses have to be next to each other and take the same number of
parameters. `_` in the `Book` clause is a wildcard: the title is matched and thrown
away. Chapter 4 covers patterns in detail. For now, remember that each parameter
position in a clause head is a pattern.

## Guards

A clause can be split further by conditions. Each guard starts with `|`, has its own
body, and the guards are tried in order. `otherwise` is the conventional last guard.

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

If none of a clause's guards hold, matching moves on to the next clause. A single
guard can also sit on the same line as the clause head: `drop n xs | n <= 0 = xs`.

> ⚠️ **A clause guard uses `|`; a `match` arm guard uses `if`.** The two are not
> interchangeable, and mixing them up is a parse error. Inside `match`, write
> `pattern if condition => body`:
>
> ```
> error: guards.mdk:2:4: a match-arm guard uses `if`, not `|` — write `pat if cond
> => body` (Medaka has no or-patterns)
> ```

## `where`

`where` attaches local definitions to a function. They are visible in the body, and
when the `where` sits at the same indentation as the guards, across all of the guards
too, as `budget` was above. A local definition can itself have clauses:

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

`where` can also follow the body on the same line, with the definitions indented on
the next line. Both spellings parse, but `medaka fmt` rewrites the trailing form to
the one shown above, so that is the one you will see.

## Lambdas

An anonymous function is `params => body`. The parameters are listed before a single
arrow, with no backslash or keyword in front.

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

A lambda parameter is a pattern, just like a clause parameter, so a lambda can
destructure its argument: `(Some x) => x`, `(a, b) => a + b`, `_ => 0`.

> ⚠️ **`(x, y) => …` takes one tuple, not two arguments.** Parentheses around a
> lambda's parameters make a tuple pattern. Two parameters are written with a space
> between them, `x y => …`, and the habit of parenthesizing them is easy to bring from
> other languages. The resulting type error points at the call site, not at the
> lambda.

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

When a lambda's whole job is to match on its argument, write `x => match x` and put
the arms underneath. This shows up a lot in arguments to `map`:

```medaka
main =
  println
    (map
      (x => match x
        Some n if n > 100 => "a big \{n}"
        Some n => "just \{n}"
        None => "nothing")
      [Some 5, Some 500, None])
```

```medaka-expect
[just 5, a big 500, nothing]
```

The arms are tried top to bottom, so the guarded `Some n if n > 100` has to come
before the plain `Some n`, or it would never run.

## Pipes, composition, and sections

Three pieces of syntax keep chains of calls readable.

`x |> f` applies `f` to `x`. A chain of pipes reads in the order the steps happen,
instead of inside out. `f >> g` composes two functions left to right, and `f << g`
right to left, giving a new function without naming its argument. A section is an
operator with one side filled in: `(+ 5)` is `x => x + 5`, `(2 * _)` is `x => 2 * x`,
with `_` marking the missing operand when it is on the right. A bare `(+)` or `(==)`
is the operator as an ordinary function.

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

`verdict` never names the expense it is given. That reads well when the pipeline is
the explanation, as here. When a reader would have to trace the composition to work
out what the argument was, name it instead.

Next: [describing the data](04-data-modeling.md) that these functions take apart.
