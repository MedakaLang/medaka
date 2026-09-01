# Effects & IO

You have been doing IO since chapter 1: a `println` in `main` prints. This chapter
explains what the compiler was tracking while you did it, and how to read and write
the effect row that appears in a signature.

## IO is a sequence of statements

To do several things in order, write them one per line, indented under the
definition. There is no keyword to open such a block and no wrapper type around the
result.

```medaka
banner : String -> <IO> Unit
banner title =
  println "=="
  println title
  println "=="

main =
  let name = "August"
  banner name
  if name == "August" then println "month closed"
```

```medaka-expect
==
August
==
month closed
```

A block's value is the value of its last statement. `let`, `if`, nested blocks, and
calls to other functions that do IO all work inside one. The only rule is that a
statement whose value is not `Unit` cannot stand on its own; the compiler will not let
a result be thrown away silently.

## The effect row

If IO is not marked by a wrapper type, what stops any function from printing? The
signature does. A function type can carry an effect row, a list of labels in angle
brackets in front of the result type:

```medaka
double : Int -> Int
double n = n * 2

shout : String -> <IO> Unit
shout s = println s

main =
  println (double 21)
  shout "loud"
```

```medaka-expect
42
loud
```

`shout` says `<IO>`, so it may print. `double` has no row, which means it performs no
effects, and the compiler holds it to that. Add a `println` to its body and checking
fails:

```
error: probe.mdk:4:2: Effectful value used where <> is allowed, but it performs <IO>
error: probe.mdk:4:2: Function 'double' declared with <> but also performs <IO>
```

So a signature tells you whether a function can touch the outside world, and the
answer is checked. You do not have to read the body, and you do not have to trust a
naming convention.

Effect rows are inferred like everything else, so the compiler would have worked out
`<IO>` for `shout` on its own. Write the row on top-level definitions anyway, for the
same reason you write the rest of the signature.

## Labels name capabilities

Each label in a row names something in the host environment. The built-in labels
are `Stdout`, `Stderr`, `Stdin`, `Clock`, `Env`, `Exec`, `Rand`, `Net`, `FileRead`,
`FileWrite`, and `FFI`. A row can name them individually:

```medaka
nap : Int -> <Clock> Unit
nap ms = sleepMs ms

configured : Unit -> <Env> String
configured () = match getEnv "MEDAKA_GUIDE_DEMO"
  Some v => v
  None => "unset"

main =
  nap 1
  println (configured ())
```

```medaka-expect
unset
```

`IO` is the umbrella label. A row of `<IO>` permits any of the labels above except
`FFI`, which has to be named on its own because it leaves the language. Write `<IO>`
when you mean "this touches the world" and the specific labels when you want the
signature to say which part of the world. `<Clock, IO>` is legal and means the same
as `<IO>`, since `IO` already includes `Clock`.

```medaka
tick : String -> <Clock, IO> Unit
tick msg =
  sleepMs 1
  println msg

main =
  tick "first"
  tick "second"
```

```medaka-expect
first
second
```

A function cannot claim a narrower row than the functions it calls. `println` is
declared `<IO>` in the prelude, so a function that calls it cannot be annotated
`<Stdout>`. Narrowing what a caller has to permit would hide an effect, and the
compiler refuses it.

You can declare your own labels with `effect`, and rows can contain variables
(`<e>`) and open tails (`<IO | e>`) so that a higher-order function can pass its
argument's effects through. Those are out of scope for this guide; the
[syntax reference](../spec/SYNTAX.md) has the spellings.

## What `do` is not

If you have used a language where IO lives in a `do` block, do not reach for `do`
here. Medaka has `do`, and chapter 8 is about it, but it is for chaining `Option`,
`Result`, and similar values, not for sequencing IO. Putting `println` statements in
a `do` block is an error:

```
error: probe.mdk:3:12: this `do` block needs a Thenable value here (like `Option` or
`Result`), but got Unit. If Unit isn't itself monadic, use 'let' instead of '<-' to
bind it.
  |
3 |     println "step one"
  |             ^
```

> ⚠️ **`<-` only works inside `do`.** It is the piece of `do` syntax that most often
> leaks into a plain block, because it is what other languages build IO blocks from.
> In a plain block it is an error that names the fix:
>
> ```
> error: probe.mdk:5:16: `<-` bind is only valid inside a `do` block. For IO
> sequencing use a bare indented block without `<-`
> ```

## Mutation is not an effect

`Ref` cells, from chapter 2, are the other thing people mean by "side effect", and
Medaka does not track them. Writing to a cell carries no label. A function that
allocates a `Ref`, mutates it, and reads it back is pure as far as the type system
is concerned:

```medaka
sumTo : Int -> Int
sumTo n =
  let total = Ref 0
  let step = i => total := !total + i
  let _ = map step [1..=n]
  !total

main = println (sumTo 10)
```

```medaka-expect
55
```

`sumTo` has no row and needs none. A `Ref` created inside a function and never
handed out is invisible from outside: same input, same output. The row tracks the
observable boundary, meaning the console, the filesystem, the clock, and the
network, not every assignment.

> ⚠️ **An empty row does not mean "no mutation".** It means the function cannot
> reach the world. A `Ref` passed in as an argument can still be written to by a
> function with no row, and the caller sees the write. Read the parameter types, not
> only the row.

## The expense log, from a file

The ledger has been a literal list so far. Real ledgers live on disk. File access is
`<IO>` like everything else, and the read returns a `Result` because it can fail.

```medaka
import io.{readLines}

logPath : String
logPath = "expenses.log"

writeLog : <IO> Result String Unit
writeLog =
  writeFile logPath "2026-08-01,Cafe Fish,4.50\n2026-08-02,Landlord,1200.0\n"

countEntries : String -> <IO> Int
countEntries path = match readLines path
  Ok ls => length ls
  Err _ => 0

main = match writeLog
  Err e => println "could not write the log: \{e}"
  Ok () =>
    println "wrote \{logPath}"
    println (countEntries logPath)
```

```medaka-expect
wrote expenses.log
2
```

The failure is a value. `readLines` returns `Result String (List String)`, so there
is nothing to catch and nothing to forget, only a `match` you cannot skip. Notice
also that the effect and the failure are tracked separately. `<IO>` in the row says
the function touches the disk. `Result` in the return type says the touch might not
work. Neither implies the other.

> **Coming from Haskell?** `readLines path` is not an action you build and later
> run. It performs the read where it is written, and its type is the value it
> produced. The effect row replaces the `IO` wrapper, so there is no `IO` in a type
> constructor position anywhere.

Turning those lines into `Expense` values is a chain of steps that can each fail.
That is what `do` is for, and [chapter 8](08-do-and-thenables.md) picks up there.
