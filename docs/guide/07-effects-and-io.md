# Effects & IO

Here is the surprise, up front: **in Medaka, imperative IO is a bare indented block.**
Not `do`. Not a wrapper type. You write the statements one under the other and they
happen in that order.

```medaka
main =
  println "reading the ledger"
  println "3 entries"
  println "done"
```

```medaka-expect
reading the ledger
3 entries
done
```

That is the whole mechanism. An indented block under `=` is a sequence of statements
whose value is the value of the last one; a statement that performs IO performs it
where it is written. `let` works inside such a block, so does `if`, so does a nested
block, and so does a call to another function that does IO.

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

If you are coming from Haskell, ML, or Scala, the instinct is to reach for `do`. Do
not. `do` exists in Medaka and [chapter 8](08-do-and-thenables.md) is about it, but it
is sugar for chaining `Option`, `Result`, and other `Thenable` values, and it does not
sequence IO. The compiler says so directly:

```
error: probe.mdk:3:12: this `do` block needs a Thenable value here (like `Option` or
`Result`), but got Unit. If Unit isn't itself monadic, use 'let' instead of '<-' to
bind it.
  |
3 |     println "step one"
  |             ^
```

(A second, cascading "Ambiguous instance for `Display`" error follows it, pointing at
the `do` keyword; fixing the first makes it go away too.)

Side by side, so the difference is concrete. The bare block sequences three effects
and produces `Unit`:

```medaka
main =
  println "step one"
  println "step two"
  println "step three"
```

```medaka-expect
step one
step two
step three
```

The `do` block chains three computations that might each fail, and produces an
`Option`:

```medaka
step : Int -> Option Int
step n = if n < 100 then Some (n * 2) else None

chain : Int -> Option Int
chain start = do
  a <- step start
  b <- step a
  c <- step b
  pure c

main =
  println (chain 1)
  println (chain 40)
```

```medaka-expect
Some 8
None
```

Same keyword-free layout, entirely different job. One is *when things happen*; the
other is *what happens if a step declines to produce a value*.

> ⚠️ **`<-` is only legal inside a `do` block.** It is the one construct that reliably
> leaks from the `Thenable` world into the IO one, because it is what every other
> language's IO block is built from. In a bare block it is a located error naming the
> fix:
>
> ```
> error: probe.mdk:5:16: `<-` bind is only valid inside a `do` block. For IO
> sequencing use a bare indented block without `<-`
> ```

## The effect row is the contract

If IO is not tracked by a wrapper type, what stops any function anywhere from
printing? The type does. A signature may carry an **effect row** — a comma-separated
list of labels in angle brackets, sitting where the arrow's effects belong.

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

`double` has no row, which means it performs no effects, and the compiler holds it to
that. Adding a `println` to its body is a type error, not a code review comment:

```
error: probe.mdk:4:2: Effectful value used where <> is allowed, but it performs <IO>
error: probe.mdk:4:2: Function 'double' declared with <> but also performs <IO>
```

This is the payoff. A function's *signature* tells you whether calling it can touch
the world, and the answer is checked. You do not have to read the body, and you do
not have to trust a naming convention.

Rows are inferred, so you only write one when you want the documentation — but on a
top-level definition you almost always do.

## The labels are capabilities

Every label in a row names a host capability. The built-in vocabulary is `Stdout`,
`Stderr`, `Stdin`, `Clock`, `Env`, `Exec`, `Rand`, `Net`, `FileRead`, `FileWrite`,
and `FFI`, and you can write them individually:

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

`IO` is the coarse alias over that vocabulary: a bound of `<IO>` admits any of the
narrow labels above except `FFI`, which has to be named literally because it crosses
out of the language. So `<Clock, IO>` is legal, and means exactly what `<IO>` means —
`IO` already covers `Clock`. Write `<IO>` when you mean "this touches the world", and
write the narrow labels when you want the signature to be specific about *which* part
of the world.

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

Going the other way does not work: `println` is declared `<IO>` in the prelude, so a
function that calls it cannot claim the narrower `<Stdout>`. Narrowing what a caller
must permit is the unsafe direction, and it is refused.

Custom `effect` labels, the capability platform that decides who may supply one, and
effect *variables* (`<e>`, and open rows like `<IO | e>`) are all real and all out of
scope here — see [the syntax reference](../spec/SYNTAX.md) for the spellings.

## Mutation is not an effect

`Ref` cells, from [chapter 2](02-expressions.md), are the other thing people mean by
"side effect", and Medaka deliberately does not track them. Writing a cell carries no
effect label, so a function that allocates a `Ref`, mutates it, and reads it back is
*pure* — and the compiler agrees:

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

`sumTo` has no row and does not need one. The reasoning is that a `Ref` created
inside a function and never handed out is invisible from the outside: same input,
same output. What the effect row tracks is the *observable* boundary — the console,
the filesystem, the clock, the network — not every assignment.

> ⚠️ **An empty effect row is not a purity certificate.** It says the function cannot
> reach the world; it does not say the function never mutates. A `Ref` that is passed
> in as an argument and written to is still `<>`, and its writes are still visible to
> whoever handed it over. Read the parameter types, not just the row.

## The expense log, from a file

The running example has been a literal list so far. Real ledgers live on disk. File
access is `<IO>` like everything else, and the read hands back a `Result` because it
can fail.

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

Two shapes are worth copying out of that. The failure is a value — `readLines`
returns `Result String (List String)`, so there is nothing to catch and nothing that
can be forgotten, only a `match` you cannot skip. And the effects and the failures
are tracked by two *different* mechanisms that happen to appear together: `<IO>` in
the row says the function touches the disk, `Result` in the return type says the
touch might not work. Neither one implies the other.

> **Coming from Haskell?** `readLines path` is not an `IO (Either …)` action you
> build and then run — it *is* the read, performed where you wrote it, and its type
> is the value it produced. The effect row replaces the `IO` wrapper, so there is no
> `runIO`, no unwrapping, and no `IO` in a type constructor position.

Turning those lines into `Expense` values is a chain of steps that can each fail —
which is exactly the job `do` was built for, and exactly where
[chapter 8](08-do-and-thenables.md) picks up.
