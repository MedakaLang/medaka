# Values, Bindings & Types

This chapter covers the pieces a program is made of: the literals you can write, how
you give them names, what to do when you need mutable state, and how much of the type
system you have to write down yourself.

## Literals

Medaka has the usual scalar types, plus tuples and two kinds of sequence. A top-level
value is declared with a name, `=`, and an expression.

```medaka
int = 5
float = 3.14
bool = True
string = "hello 👋"  -- strings are UTF-8
pair = (False, 7)  -- a tuple
list = [1, 2, 3]  -- a linked list
array = [|"a", "b", "c"|]  -- an array

main = println list
```

```medaka-expect
[1, 2, 3]
```

`List` and `Array` are different types with different costs. `[1, 2, 3]` builds a
linked list, `[|1, 2, 3|]` a contiguous array. Chapter 6 covers when to use which.
Until then, the examples use lists.

## Everything is an expression

`if` and `match` produce values, so they can appear anywhere a value can, including
on the right-hand side of a binding.

```medaka
main =
  let n = 7
  let label = if n > 5 then "big" else "small"
  println label
```

```medaka-expect
big
```

There is no ternary operator and no `return`, because `if` already is the conditional
expression. You can leave off the `else`, but then the `if` has no value on the false
side, so it evaluates to `()` and the `then` branch has to be `Unit` as well. An `if`
without `else` is for side effects only. Dropping the `else` in the program above is
a type error:

```
error: probe.mdk:3:28: Type mismatch: String vs Unit
  |
3 |   let label = if n > 5 then "big"
  |                             ^
```

## Bindings are immutable

A binding is a declaration, not an assignment. Each name is defined once in its scope
and cannot be written to afterwards.

```medaka-nocheck: intentionally invalid duplicate declaration
int = 4
int = 5 -- error
```

The second line is rejected:

```
Duplicate binding 'int': it is already defined in this scope. A value binding has
exactly one definition — rename this one or remove it
```

Inside an expression, `let … in` declares a local binding.

```medaka
list = let five = 5 in [4, five, 6]
```

When there are several, put each `let` on its own line and leave off the `in`. Each
binding is visible for the rest of the block.

```medaka
list =
  let five = 5
  [4, five, 6]
```

You can reuse a name with a new `let`. That is shadowing, not reassignment: it
declares a fresh binding, and the old one is out of reach from then on.

```medaka
main =
  let x = 1
  let x = x + 1  -- a new binding; the `x` on the right is the old one
  println x
```

```medaka-expect
2
```

## Mutable state goes in a `Ref`

When you need something that changes, put the value in a `Ref` cell. The binding is
still immutable, since it always names the same cell, but the cell's contents can
change. `:=` writes to a cell and `!` reads from it.

```medaka
main =
  let count = Ref 0
  count := 42
  count := !count + 1
  println !count
```

```medaka-expect
43
```

`!` binds tighter than function application, so `println !count` means
`println (!count)`.

> ⚠️ **`!` reads a `Ref`. It is not "not".** If you are used to `!x` meaning Boolean
> negation, this will catch you once. Negation in Medaka is spelled `not x`, and
> applying `!` to a `Bool` is an error:
>
> ```
> error: probe.mdk:1:16: `!` is dereference (Ref), not boolean negation — use `not x`
> ```

## Types you write, and types you don't

The compiler infers the type of every binding in this chapter without being told.
You can still write types anywhere, and on top-level definitions you should: a
signature is the first thing a reader looks at, and it pins down what you meant even
when inference would have found something more general.

A signature goes on its own line above the definition. You can also annotate an
expression inline, or a `let`.

```medaka
int : Int
int = 4

pairWithFloat : (String, Float)
pairWithFloat = ("abc", 1.23)

annotatedInExpression = 5 : Int

list = let nums = [1, 2, 3] : List Int in if True then nums else []
```

A lowercase name in a signature is a type variable. It stands for any type, and the
function has to work for all of them. A constraint before `=>` narrows that to any
type that implements a given interface. Chapter 5 covers interfaces; for now, read
`Eq a =>` as "any `a` that supports `==`".

```medaka
identityOf : a -> a
identityOf v = v

sameAs : Eq a => a -> a -> Bool
sameAs p q = p == q

main = println (sameAs 1 1)
```

```medaka-expect
True
```

A signature can also carry an effect row, which says what the function is allowed to
do besides compute. `<IO>` below is what lets `shout` print. A signature with no row
means the function is pure, and the compiler checks that too.

```medaka
shout : String -> <IO> Unit
shout s = println s

main = shout "quiet please"
```

```medaka-expect
quiet please
```

Effects have their own chapter, chapter 7. For now, the thing to know is that the row
is part of the type and is checked like the rest of it.

Next: [functions](03-functions.md).
