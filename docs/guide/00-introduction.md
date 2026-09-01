# Introduction

Medaka is a small functional language for everyday programming. It has algebraic
data types, pattern matching that the compiler checks for completeness, type
inference, interfaces for overloading, and an effect system that records in a
function's type what that function is allowed to touch. Programs compile to native
code through LLVM or to WebAssembly, and the compiler, formatter, linter, test
runner, and language server all live in one `medaka` binary.

This guide is for people who already know how to program in some language. It does
not assume which one. It teaches how things are done in Medaka rather than
programming from scratch, so it moves quickly and skips the parts you already know.

> **Coming from Haskell or OCaml?** You already have most of the concepts. The
> [delta sheet](haskell-ocaml-delta.md) lists the places where the spelling or the
> rules differ, and you can skim the rest of the guide.

## A first look

```medaka
data Expense = Coffee Float | Rent Float | Book String Float

cost : Expense -> Float
cost (Coffee c) = c
cost (Rent r) = r
cost (Book _ p) = p

main =
  let expenses = [Coffee 4.5, Rent 1200.0, Book "SICP" 35.0]
  let total = expenses |> map cost |> sum
  println "You logged \{length expenses} expenses."
  println "Total spent: $\{total}"
```

It prints:

```medaka-expect
You logged 3 expenses.
Total spent: $1239.5
```

Reading it top to bottom: `Expense` is a type with three constructors. `cost` is one
function written as three clauses, one per constructor. `main` builds a list, sends it
through `map` and `sum` with the pipe operator, and prints two lines using string
interpolation. Each of those gets a chapter. The expense tracker comes back throughout
the guide as its running example, and by chapter 8 it reads its data from a file and
parses it.

## What you get

- **Static types, inferred.** The compiler works out the types of your program. You
  write signatures on top-level definitions because they document, not because the
  compiler needs them.
- **Data types and pattern matching.** You describe the shapes your data can take, and
  every place that takes a value apart has to handle every shape. Forget one and the
  compiler names it.
- **Interfaces.** Overloading by type, in the style of Haskell's typeclasses or Rust's
  traits. `==`, `<`, printing, and arithmetic all go through them, and you can add your
  own.
- **Effects in the type.** A signature like
  `readLines : String -> <IO> Result String (List String)` says the function can do
  IO. A function with no effect row is pure, and the compiler enforces it.
- **No null, no exceptions.** A value that might be missing is an `Option`. An operation
  that might fail returns a `Result`. Both are ordinary data types, so the pattern
  matching checker makes sure you handle them.
- **One binary.** `medaka check`, `run`, `build`, `fmt`, `lint`, `test`, `repl`, and
  `lsp` are subcommands of the same executable. There is nothing else to install.

## How to read this guide

The chapters build on each other, so the first time through, read them in order.

1. [Quick Start](01-quick-start.md). Your first program, and how to run it.
2. [Values, Bindings & Types](02-expressions.md). Literals, `let`, mutable cells,
   and what a signature buys you.
3. [Functions](03-functions.md). Clauses, guards, lambdas, and the pipe operator.
4. [Data Modeling](04-data-modeling.md). Sum types, records, pattern matching, and
   why `Option` replaces null.
5. [Interfaces](05-interfaces.md). Overloading, constraints, and `deriving`.
6. [Working with Data](06-working-with-data.md). Lists, arrays, maps, strings, and
   the `map`/`filter`/`fold` vocabulary.
7. [Effects & IO](07-effects-and-io.md). How IO is written, and what the effect row
   in a signature means.
8. [`do` and Thenables](08-do-and-thenables.md). Chaining computations that can
   fail.
9. [Modules & Projects](09-modules-and-projects.md). Splitting a program across
   files.
10. [Tooling & Workflow](10-tooling-and-workflow.md). The `check`, `fmt`, `lint`,
    and `test` loop.

Every example in this guide is compiled by the test suite before a change can merge.
Examples with output shown beneath them are also run, and the output is compared. If
the guide says a program prints something, that is what the current compiler prints.

## Why Medaka?

I spent a lot of time in college working in Haskell, a wonderful language that gave
me a deep appreciation for functional programming. Since then I've been working in
industry, mostly with more "practical" (though in my experience much less elegant)
languages like Typescript. I miss Haskell's elegance, but there are many elements
of it that make it a hard sell for projects where _what_ you're delivering is much
more important than _how_ you got there. Part of this goes to Haskell's nature as
both a general purpose programming language and a research language that is
always looking to push the boundaries of what a functional language can be. OCaml
fixes some of these issues with practicality, but it also lacks some of my favorite
features from Haskell, like typeclasses and the beautiful declarative syntax. The
truth is that both of these languages are getting a bit old, and while they have
more than contributed their share to the world of functional programming, there are undoubtedly
some decisions they made early in their lives that they would change given what we
know today.

Medaka seeks to be a pragmatic, modern language that builds on the groundwork laid
by these functional forebears. Medaka is oriented much more towards **getting things
done** than being a research project. Medaka is strongly biased in favor of simplicity
over complexity in its feature set, choosing to forgo some of the more esoteric
functional programming features in favor of a cohesive and comprehensible set of
core features. The goal is to take the best pieces from languages like Haskell and
OCaml (with some additional inspiration from languages like Rust, Elm, and F#) and
package them up in a sleek, modern shell that enables programmers to become productive
in Medaka very quickly.
