# Effects VI: Effect-Indexed Types

A function's row says what applying it performs. A data type can hold a function
and expose its row as a parameter of the type, so that a `Job <Stdout> Int` is a
job that will print when run and a `Job <> Int` is one that will not. This is the
mechanism behind deferred computation in Medaka, and it is short.

## Declaring the kind

A type parameter that is used as a row has to be declared as one. The kind is
written on the head:

```medaka
data Job (e : Effect) a = Done a | Later (Unit -> <e> Job e a)

runJob : Job e a -> <e> a
runJob job = match job
  Done v => v
  Later k => runJob (k ())

delay : (Unit -> <e> a) -> Job e a
delay body = Later (() => Done (body ()))

main =
  let pureJob = delay (() => 40 + 2)
  let loudJob = delay (() => putStrLn "working")
  println (runJob pureJob)
  runJob loudJob
```

```medaka-expect
42
working
```

`(e : Effect)` says `e` is a row, not a type, and the `Later` constructor stores
a function whose latent row is `e`. `delay` wraps a computation without running
it: `check` prints `delay : (Unit -> <a> b) -> Job a b`, with no row on its own
arrow, because constructing a `Job` performs nothing. `runJob` is where the row
comes out: `runJob : Job a b -> <a> b`. Whatever was stored is charged when it is
run, and only then.

Leave the kind off and the compiler asks for it:

```
error: indexed.mdk:3:11: type parameter `e` of `Job` is used as an effect row, but its head does not declare it one; declare the head as `Job (e : Effect) ...`
  |
3 |   | Later (Unit -> <e> Job e a)
  |            ^
```

A parameter's kind is `Type` unless it is written otherwise, and a kind is never
inferred from how a field happens to use it.

## The index is a row you can write

Because the index is a row, a signature can pin it:

```medaka
data Job (e : Effect) a = Done a | Later (Unit -> <e> Job e a)

runJob : Job e a -> <e> a
runJob job = match job
  Done v => v
  Later k => runJob (k ())

delay : (Unit -> <e> a) -> Job e a
delay body = Later (() => Done (body ()))

quiet : Job <> Int
quiet = delay (() => 40 + 2)

loud : Job <Stdout> Unit
loud = delay (() => putStrLn "working")

main =
  println (runJob quiet)
  runJob loud
```

```medaka-expect
42
working
```

`quiet : Job <> Int` is a job that is guaranteed not to perform anything when run.
Like an authority index, an effect index is invariant: a `Job <Stdout> Unit` is
not a `Job <> Unit`, and a function that only accepts the latter refuses the
former where it is built:

```
error: indexed.mdk:13:47: performs <Stdout> where only <> is allowed
  |
13 | main = println (runPure (delay (() => putStrLn "sneaky")))
  |                                                ^
```

Here `runPure : Job <> a -> a` runs a job with no row of its own, which is honest
only because its argument's index is empty. Widening the index to `<Stdout>`
would let `runPure` print from a pure position, so the compiler holds the index
fixed and reports the callback that does not fit. When the two indices are both
already written, the message names the invariance directly:

```
error: indexed.mdk:4:10: effect index mismatch: <Stdout> vs <>; an effect row in a type argument is invariant, so write the same row on both sides or use a row variable, `<Stdout | e>`
  |
4 | widen j = j
  |           ^
```

for `widen : Job <> Int -> Job <Stdout> Int` with `widen j = j`.

## Combining indices

A function that combines two jobs has a result whose index is the join of both.
In an index slot the join is written with parentheses rather than angle
brackets:

```medaka
data Job (e : Effect) a = Done a | Later (Unit -> <e> Job e a)

runJob : Job e a -> <e> a
runJob job = match job
  Done v => v
  Later k => runJob (k ())

delay : (Unit -> <e> a) -> Job e a
delay body = Later (() => Done (body ()))

both : Job e a -> Job e2 b -> Job (e | e2) (a, b)
both x y = Later (() => Done (runJob x, runJob y))

main =
  let pair = both (delay (() => 1)) (delay (() => putStrLn "side"))
  let (n, ()) = runJob pair
  println n
```

```medaka-expect
side
1
```

`Job (e | e2) (a, b)` is a job whose run performs whatever either input's run
performs. The two variables stay independent in the type, the same way two tails
did in [chapter 2](effects-2-polymorphism.md); the body's `runJob x` and
`runJob y` are charged `e` and `e2`, and `Later` stores that joined row.

## Where this leads

A type like `Job` becomes useful once it has `map`, `pure`, and a bind, so that
jobs compose the way `Option` and `Result` do in a `do` block. Those cannot be the
plain `Mappable`, `Applicative`, and `Thenable` interfaces from
[chapter 8 of the guide](../guide/08-do-and-thenables.md): their methods take a
type constructor of one argument, and a bind on `Job` changes the index, from
`Job e a` and `a -> Job e2 b` to `Job (e | e2) b`. The prelude has a second
family of interfaces for exactly this shape, `DeferredMappable`,
`DeferredApplicative`, and `DeferredThenable`, and a `defer` block that is `do`
over that family. Their contracts and the rules for implementing them honestly
are in the [effects specification](../spec/EFFECTS-SEMANTICS.md), §6.6 and §6.7,
and the syntax of a `defer` block is in the
[syntax reference](../spec/SYNTAX.md). A future topic in this section will cover
them in the same depth as effects.
