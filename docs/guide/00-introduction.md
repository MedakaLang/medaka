# Introduction

Medaka is a declarative functional language designed to be practical for everyday
use. It takes the ideas that make functional programming worth doing — algebraic
data types, exhaustive pattern matching, type inference, ad-hoc polymorphism — and
packages them in a small, cohesive language with a compiler, a formatter, a linter,
a test runner, and a language server in one binary.

This guide is for people who already know how to program. It teaches *Medaka's way*
of doing things rather than programming from first principles, so it moves quickly
and assumes you can read a type signature.

> **Already comfortable with Haskell or OCaml?** Start with the
> [Haskell and OCaml delta sheet](haskell-ocaml-delta.md), then return
> here for the main guide.

## What you get

- **Strong static typing** with Hindley–Milner inference. You rarely write a type;
  you write signatures because they document, not because the compiler needs them.
- **Declarative syntax** in the Haskell tradition — significant indentation, no
  braces, definitions by pattern-matching clauses.
- **Ad-hoc polymorphism through `interface`s** (typeclasses by another name; `trait`s
  if you're coming from Rust), including constrained and conditional implementations.
- **An effect system that lives in the type.** A signature says what a function is
  allowed to touch: `readFile : String -> <IO> String`, `fetch : String -> <Clock, IO> String`.
  The row is checked, not decorative — annotate a printing function as pure and the
  compiler tells you it "declared with `<>` but also performs `<IO>`". Effect labels
  name host capabilities, which is what makes a Medaka signature a contract about the
  outside world and not just about values.
- **Two backends.** `medaka build` compiles to a native binary through LLVM and
  `clang`; a WebAssembly backend runs the same compiler in the browser, which is how
  [the playground](https://medaka-lang.dev) works with no server behind it.
- **Tooling in the box.** `medaka check`, `run`, `build`, `fmt`, `lint`, `test`
  (doctests and property tests), `repl`, and `lsp` are all subcommands of the one
  binary — there is nothing to assemble before you start.

Here's a small sample:

```medaka
data Expense =
  | Coffee Float
  | Rent Float
  | Book String Float

cost : Expense -> Float
cost (Coffee c) = c
cost (Rent r)   = r
cost (Book _ p) = p

main =
  let expenses = [Coffee 4.50, Rent 1200.0, Book "SICP" 35.0]
  let total = expenses |> map cost |> sum
  println "You logged \{length expenses} expenses."
  println "Total spent: $\{total}"
```

It prints:

```medaka-expect
You logged 3 expenses.
Total spent: $1239.5
```

Nothing in that program is explained yet, and that is deliberate — it is a taste, not
a lesson. A sum type with three variants, a function defined as three clauses that
match on them, a pipeline built with `|>`, string interpolation with `\{ }`, and an
indented block of statements for the IO at the end. Every one of those gets its own
chapter. The expense tracker comes back as the guide's running example once there is
enough language to build it properly.

## Where to go next

- **[Quick Start](01-quick-start.md)** — your first running program, in about five minutes.
- **[Values, Bindings & Types](02-expressions.md)** — literals, bindings, mutation, and
  what a type signature buys you.
- **[Medaka for Haskell and OCaml readers](haskell-ocaml-delta.md)** — the deltas, if you
  already have the concepts and just need the spellings.

Every example in this guide is extracted and run against the compiler on every commit,
so what you read here is what the current compiler actually does.

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
