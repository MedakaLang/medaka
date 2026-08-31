# Values, Bindings & Types

This chapter covers what goes inside a program: the literals you write, the names you
bind them to, what to do when you genuinely need mutable state, and how much of the
type system you have to say out loud.

## Literals

Medaka has the usual scalars plus two distinct sequence types and tuples. A top-level
value is declared with a name and `=`.

```medaka
int = 5
float = 3.14
bool = True
string = "hello 👋" -- strings are utf8 by default
pair = (False, 7) -- tuples
list = [1, 2, 3] -- a linked list
array = [|"a", "b", "c"|] -- an in-memory array

main = println list
```

```medaka-expect
[1, 2, 3]
```

`List` and `Array` are different types with different costs, not two spellings of one
idea — `[1, 2, 3]` builds a cons list, `[|1, 2, 3|]` an array. Chapter 6 covers when to
reach for which; until then the examples use lists.

## Everything is an expression

`if` and `match` are not statements — they evaluate to a value, so they can appear
anywhere a value can, including directly on the right of a binding.

```medaka
main =
  let n = 7
  let label = if n > 5 then "big" else "small"
  println label
```

```medaka-expect
big
```

This is why there is no ternary operator and no `return`: an `if` with no `else` would
have nothing to evaluate to, so `else` is not optional.

## Bindings are immutable

A binding is a *declaration*, not an assignment. Each name is defined exactly once in
its scope, and there is no way to write to it afterwards.

```medaka-nocheck: intentionally invalid duplicate declaration example
int = 4
int = 5 -- ❌ error!
```

That second line is rejected with
`Duplicate binding 'int': it is already defined in this scope. A value binding has
exactly one definition — rename this one or remove it`.

Inside an expression, `let ... in` declares a local binding.

```medaka
list = let five = 5 in [4, five, 6]
```

You can also put `let`s on separate lines for readability, leaving off the `in`. Each
one scopes over the rest of the block.

```medaka
list =
  let five = 5
  [4, five, 6]
```

Shadowing is not reassignment, and it is allowed: a *new* `let` that reuses a name
declares a fresh binding, and the old one is simply out of reach from there on.

```medaka
main =
  let x = 1
  let x = x + 1 -- a new binding; the `x` on the right is still the old one
  println x
```

```medaka-expect
2
```

## Mutable state lives in a `Ref`, not in the binding

When you genuinely need to mutate something, put the value in a `Ref` cell. The
*binding* stays immutable — it always names the same cell — while the cell's *contents*
can change. `:=` writes the cell and `!` reads it.

```medaka
main =
  let count = Ref 0 -- an immutable binding of a mutable cell
  count := 42       -- `:=` writes
  count := !count + 1
  println !count    -- `!` reads
```

```medaka-expect
43
```

`!` binds tighter than function application, so `println !count` is `println (!count)`
and needs no parentheses.

> ⚠️ **`!` is dereference, not Boolean negation.** Coming from C, JavaScript, or Rust
> this is the one that will catch you. `not` is Medaka's only spelling for negation.
> Applying `!` to a `Bool` is a located error, not a silent surprise:
>
> ```
> error: probe.mdk:1:16: `!` is dereference (Ref), not boolean negation — use `not x`
> ```

## Types you write, and types you don't

Type inference means you rarely *need* a signature — the compiler works out the types
of the program above without being told any of them. You are free to add annotations
anywhere, and we strongly recommend a signature on every top-level declaration, for
readability and documentation rather than for the compiler.

A signature sits on its own line above the definition. Annotations can also go inline,
in expression position or on a `let`.

```medaka
int : Int
int = 4

pairWithFloat : (String, Float)
pairWithFloat = ("abc", 1.23)

annotatedInExpression = (5 : Int)

list = let nums : List Int = [1, 2, 3] in if True then nums else []
```

Lowercase names in a signature are type variables — they stand for "any type", and the
function must work for all of them. A constraint before `=>` narrows that to "any type
that implements this interface", which is the subject of chapter 5.

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

A signature can also carry an effect row, saying what the function is permitted to
touch. `<IO>` here is what lets `shout` print at all; a signature without a row means
the function is pure, and the compiler enforces that.

```medaka
shout : String -> <IO> Unit
shout s = println s

main = shout "quiet please"
```

```medaka-expect
quiet please
```

Effects get their own chapter later; for now it is enough to know that the row is part
of the type and is checked like the rest of it.

Next up is chapter 3, functions — defining behavior, matching on arguments, and
composing the results.
