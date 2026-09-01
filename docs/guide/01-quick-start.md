# Quick Start

The fastest way to follow along is [the playground](https://medaka-lang.dev), which
runs every example in this guide in your browser. To work locally instead, put a
program in a file ending in `.mdk` and run it with:

```
medaka run hello.mdk
```

That type-checks the program and runs it in one step.

## Hello, world

A Medaka program starts at `main`.

```medaka
main = println "Hello world!"
```

Running it prints:

```medaka-expect
Hello world!
```

`main` is a value, not a function. You define it with `main = …` and never with
parameters. When you run the program, `main` is evaluated for its effects, in this
case printing a line.

> ⚠️ **Write `main = …`, not `main () = …`.** A `main` with a parameter is a
> function that nothing ever calls. The compiler warns about it under `medaka check`,
> and `medaka run` and `medaka build` refuse to go ahead:
>
> ```
> warning: hello.mdk:1:10: 'main' must be a value of type Unit. Write 'main = …',
> not 'main () = …' or 'main x = …' ('medaka run' never applies main; it forces a
> zero-arg main for its effects)
> ```

## Doing several things

To do more than one thing, put the statements on separate lines, indented under
`main`. They run top to bottom.

```medaka
main =
  println "What's in the box?"
  println "A fish."
```

```medaka-expect
What's in the box?
A fish.
```

That is all there is to sequencing in Medaka. There is no special keyword for a
block of statements and no wrapper type around IO. Chapter 7 explains how the
compiler still keeps track of which functions do IO.

> ⚠️ **Indentation is the syntax.** Medaka has no braces and no semicolons. The two
> `println` lines above form a block because they are indented under `main` by the
> same amount. When the indentation is wrong, the error is often not about
> indentation: a statement indented one space too far or too little is frequently
> reported as `Unbound variable`, because the compiler closed the block before it
> reached your line. If a name you can plainly see is reported as unbound, check the
> columns first.

## Comments

A line comment starts with `--` and runs to the end of the line. A block comment is
written between `{-` and `-}`, and block comments nest, so you can comment out a
region that already contains one.

```medaka
-- A line comment.
main = println (2 + 5)  -- A comment can also follow code.
```

```medaka-expect
7
```

```medaka
{- A block comment.
   It can span several lines, and {- it nests -} cleanly. -}
main = println (2 + 5)
```

```medaka-expect
7
```

Next: [values, bindings, and types](02-expressions.md), which is what goes on the
right-hand side of those statements.
