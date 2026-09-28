# Effects I: What the Row Says

[Chapter 7 of the guide](../guide/07-effects-and-io.md) introduced the effect row:
the `<IO>` in `shout : String -> <IO> Unit` says `shout` may touch the world, and
a function with no row may not. This chapter is about what the compiler is doing
behind that sentence. It covers when an effect is charged, what the compiler
infers when you write no row at all, what each built-in label stands for, and the
rows of things that are not functions.

The tool for the whole topic is `medaka check`. Besides reporting errors, it prints
the type it inferred for every top-level binding in your file, row included, so
you can see what the compiler concluded rather than guess. When this guide shows
what `check` printed, the text was pasted from the compiler.

## Latent and immediate

Building a function is pure. Calling it is what performs its effects. The row on an
arrow describes the call, not the construction:

```medaka
makeLogger : String -> String -> <Stdout> Unit
makeLogger prefix = msg => putStrLn "\{prefix}: \{msg}"

main =
  let log = makeLogger "app"
  putStrLn "logger built, nothing printed yet"
  log "first"
  log "second"
```

```medaka-expect
logger built, nothing printed yet
app: first
app: second
```

`makeLogger "app"` returns a closure and prints nothing. The `<Stdout>` sits on the
last arrow, the one from `String` to `Unit`, because that is the arrow whose
application prints. An arrow the function only passes through on the way to
another arrow is pure. (`String -> (String -> <Stdout> Unit)` is the same type;
the formatter drops the parentheses.)

So an expression has two kinds of effect. Its *immediate* row is what evaluating
it performs. Its *latent* rows sit on the arrows in its type and are released when
those arrows are applied. `makeLogger "app"` has an empty immediate row and a
latent `<Stdout>`; `log "first"` has an immediate row of `<Stdout>`.

## Inference

You do not have to write rows. The compiler infers them the way it infers types,
and the rule is simple: the row of a call is the join of the row of the function
expression, the rows of the arguments, and the latent row of the arrow being
applied. A definition's row is the join of everything its body does.

```medaka
double : Int -> Int
double n = n * 2

shout : String -> <IO> Unit
shout s = println s

greet name = println "hi \{name}"

twice f x = f (f x)

main =
  println (double 21)
  shout "loud"
  greet "you"
  println (twice double 5)
```

```medaka-expect
42
loud
hi you
20
```

`medaka check` prints:

```
double : Int -> Int
shout : String -> <IO> Unit
greet : Display a => a -> <IO> Unit
twice : (a -> <b> a) -> a -> <b> a
main : <IO> Unit
```

`greet` has no signature and was inferred `<IO>` because `println` is `<IO>`.
`twice` was inferred with a *variable* in its row: `twice` performs whatever its
argument performs, no more. That is effect polymorphism, and
[the next chapter](effects-2-polymorphism.md) is about it. `main` has a row too,
the join of everything it calls.

> **Coming from Koka or Haskell?** There is no effect handler and no `IO` type
> constructor. A row is a static upper bound the compiler checks and then erases;
> nothing about it exists at runtime, and the program computes the same value with
> or without its annotations.

## A signature is a bound

Write a row and the compiler checks the body against it. The body may perform
less than the row says, never more:

```medaka-nocheck: the program is refused, and the diagnostic is what the example is for
double : Int -> Int
double n =
  println "doubling"
  n * 2

main = println (double 21)
```

```
error: rows.mdk:3:10: Effectful value used where <> is allowed, but it performs <IO>
  |
3 |   println "doubling"
  |           ^
```

`<>` is the empty row, the spelling of "pure". The message names the row the
signature allows and the row the expression performs. This check is the whole
reason to write rows on top-level definitions: a signature is a promise the
compiler holds the body to, transitively. If `double` called a helper that called
a helper that printed, the same error would appear, at the call in `double`'s body
that lets the effect in.

The other direction is always fine. A pure function may be declared with a row, a
`<Stdout>` function may be declared `<IO>`, and a function declared `<Clock, IO>`
is the same as one declared `<IO>`. Declaring more than you perform is safe; it
only makes callers permit more than they need.

## The built-in labels

Every label names something in the host environment, and every extern in the
standard library's runtime catalog declares which one it performs. This is the
vocabulary:

| Label | Performed by |
|---|---|
| `Stdout` | `putStr`, `putStrLn`, `flushStdout` |
| `Stderr` | `ePutStr`, `ePutStrLn` |
| `Stdin` | `readLine`, `readLineOpt`, `readAll`, `readExactly` |
| `FileRead` | `readFile`, `readFileBytes`, `fileExists`, `listDir`, `statFile`, `canonicalizePath`, … |
| `FileWrite` | `writeFile`, `appendFile`, `makeDir`, `removeFile`, `rename`, `fsync`, … |
| `Env` | `getEnv`, `args`, `executablePath`, … |
| `Exec` | `runCommand` |
| `Net` | `netResolve`, `netTcpConnect`, `netTcpListen`, `netSend`, `netRecv`, … |
| `Clock` | `wallTimeSec`, `monotonicSec`, `sleepMs` |
| `Rand` | `randomInt`, `randomBool`, `randomFloat`, `randomChar`, `setSeed`, `osEntropyBytes` |
| `FFI` | any `extern` you declare yourself |

`IO` is not on the list because it is not a label of its own. It is a shorthand for
all ten labels above at once, so a row of `<IO>` admits any of them, and a row that
performs `<Stdout>` fits a bound of `<IO>`. Two things it does not cover: `FFI`,
which has to be named explicitly because it leaves the language, and any label you
declare yourself ([chapter 3](effects-3-labels.md)).

Narrow labels let a signature say which part of the world a function touches:

```medaka
say : String -> <Stdout> Unit
say s = putStrLn s

warn : String -> <Stderr> Unit
warn s = ePutStrLn s

now : Unit -> <Clock> Float
now () = monotonicSec ()

both : String -> <Stderr, Stdout> Unit
both s =
  say s
  warn s

main =
  say "to stdout"
  both "twice"
  let t = now ()
  if t >= 0.0 then say "clock read"
```

```medaka-expect
to stdout
twice
clock read
```

`check` prints `main : <Clock, Stderr, Stdout> Unit`. The compiler keeps rows
sorted and deduplicated, so `<Stderr, Stdout>` and `<Stdout, Stderr>` are the same
row.

> ⚠️ **`println` is `<IO>`, not `<Stdout>`.** The prelude declares `println` and
> `print` with the umbrella label, so any function that calls them is charged all
> ten labels at once. When you want a narrow row, call `putStrLn` on a string
> instead. Narrowing the prelude's declaration is tracked as
> [#2411](https://github.com/MedakaLang/medaka/issues/2411).

A function cannot claim a narrower row than the functions it calls, so this is
refused:

```
error: rows.mdk:2:16: Effectful value used where <Stdout> is allowed, but it performs <IO>
  |
2 | say s = println s
  |                 ^
```

The fix is either to widen `say` to `<IO>` or to call `putStrLn`.

Several of these labels can carry a *parameter* that says which file, which
variable, or which host: `readFile "cfg/app.toml"` performs
`<FileRead "cfg/app.toml">`, not merely `<FileRead>`. That is
[chapter 4](effects-4-authority.md). Until then, read a bare label as "any of it".

## Values have rows too

A top-level binding with no parameters is a value, and a value can still have a
row: the row of computing it. The syntax puts the row in front of the type, where
there is no arrow to hang it on:

```medaka
banner : <IO> Unit
banner = println "== banner =="

greeting : String
greeting = "hello"

count : <Stdout> Int
count =
  putStrLn "counting"
  3

main =
  banner
  println greeting
  println count
```

```medaka-expect
== banner ==
hello
counting
3
```

A top-level value is computed the first time it is used, not when the program
starts, and the result is kept. So `count` prints `counting` once even if it is
read twice. Statically, though, every use is charged: a function that mentions
`count` performs `<Stdout>` whether or not it happens to be the first to force it,
because the compiler cannot know which use comes first.

> ⚠️ **A row-less signature on a value is not a promise of purity.** `count : Int`
> says what type the value has and nothing about computing it; the compiler infers
> the row on its own, and `check` prints `count : <Stdout> Int`. To promise a value
> is computed purely, write the empty row: `count : <> Int`. That is checked, and a
> `putStrLn` in the body is then an error.

This is different from function signatures, where a missing row means `<>`.
The asymmetry exists because a value signature such as `greeting : String` has no
arrow to carry a row, and reading every such signature as a purity promise would
make most existing code a type error.

## Statements and discarded values

Inside a block, each line is a statement, and a statement that produces anything
other than `Unit` is an error:

```
error: rows.mdk:11:2: this statement's value (String) is silently discarded — only a `Unit`-typed expression may stand alone as a statement
  |
11 |   "a string statement"
  |   ^
```

This is not an effect rule, but it is the rule that keeps effect rows honest in
imperative code. A function whose result carries information, such as a
`Result` from `writeFile`, has to be matched on or bound with `let _ =`; it cannot
be dropped by accident. The two rules together mean that reading a block top to
bottom tells you both what it does and what it ignores.

## What is not an effect

The row tracks the boundary between the program and its host. Three things people
sometimes expect on it are not there, on purpose.

**Mutation.** Writing to a `Ref` cell has no label. A function that allocates a
cell, updates it, and reads it back is pure as far as the row is concerned, and so
is one that writes to a cell it was handed. Chapter 7 of the guide has the
example; the reasoning is that a cell is memory, not the world.

**Failure.** `panic` stops the program and `exit` ends it; neither has a label.
Recoverable failure is a value, `Result` or `Option`, and the type system tracks
it there.

**Allocation and time spent.** The row says nothing about cost.

What is left is exactly the set of things a host could grant or refuse: the
console, the filesystem, the environment, subprocesses, the network, the clock,
randomness, and foreign code. [Chapter 3](effects-3-labels.md) shows what a host
does with that list.
