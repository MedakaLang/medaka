# Quick Start

The quickest way to follow along is [the playground](https://medaka-lang.dev), where
you can run every example in this guide right in your browser. If you'd rather work
locally, `medaka run <file.mdk>` type-checks and runs a program in one step.

## "Hello World" in Medaka

Every Medaka program begins by declaring `main`.

```medaka
main = println "Hello world!"
```

Running it prints:

```medaka-expect
Hello world!
```

`main` is a zero-argument *value* of type `Unit`, normally an effectful expression
such as a `println`. `medaka run` forces `main` for its effects; it never applies
`main` as a function and never prints its result.

> ⚠️ **Write `main = …`, not `main () = …`.** A `main` that takes an argument is a
> different thing — a function nobody calls — so `run` and `build` refuse it rather
> than doing nothing:
>
> ```
> warning: hello.mdk:1:10: 'main' must be a value of type Unit. Write 'main = …',
> not 'main () = …' or 'main x = …' ('medaka run' never applies main; it forces a
> zero-arg main for its effects)
> ```
>
> `medaka check` reports this as a *warning* and still exits 0 — the declaration is
> perfectly well-typed, it just isn't an entry point. `medaka run` and `medaka build`
> exit non-zero. Don't rely on a green `check` alone to tell you a program will run.

## Doing more than one thing

`main` can be an indented block of statements rather than a single expression. There
is no `do` keyword involved and no special IO type — the block is just a sequence,
run top to bottom.

```medaka
main =
  println "What's in the box?"
  println "A fish."
```

```medaka-expect
What's in the box?
A fish.
```

> ⚠️ **Indentation is significant.** The block above is a block because both `println`
> lines sit at the same deeper indentation than `main`. Medaka has no braces and no
> semicolons; layout is the syntax. Get it wrong and the error usually shows up as
> something else entirely — an inconsistently indented statement is frequently reported
> as `Unbound variable`, because the compiler has closed the block before reaching your
> line. If a name you can plainly see is reported as unbound, check the columns first.

## Comments

Single-line comments begin with `--` and run to the end of the line. Block comments are
delimited by `{-` and `-}`, and they nest, so you can comment out a region that already
contains a block comment.

```medaka
-- A single-line comment.
main = println (2 + 5) -- ...which can also sit at the end of a line.
```

```medaka-expect
7
```

```medaka
{- This is a block comment.
   It can span multiple lines, and {- it nests -} cleanly.
   This will print 7 to stdout. -}
main = println (2 + 5)
```

```medaka-expect
7
```

## What just happened

You now have the shape of a Medaka program: a `main` value, an indented block for
doing several things in order, and `println` to see the results. The next chapter fills
in what goes *inside* it — [values, bindings, and types](02-expressions.md).
