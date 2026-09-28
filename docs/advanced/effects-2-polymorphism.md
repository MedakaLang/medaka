# Effects II: Effect Polymorphism

`map` takes a function and applies it to every element. If the function prints,
the call to `map` prints. If it is pure, the call is pure. `map` itself has no
opinion. Its signature in the prelude says exactly that:

```medaka-nocheck: an interface method signature quoted from the prelude, not a standalone program
map : (a -> <e> b) -> f a -> <e> f b
```

The `e` is an *effect variable*. It stands for whatever row the callback has, and
because the same `e` appears on `map`'s own arrow, `map` is charged with it. This
chapter is about writing and reading signatures like that one.

## Effect variables

A lowercase name in a row is a variable. Use it to say "this function performs
what its argument performs":

```medaka
applyTwice : (a -> <e> a) -> a -> <e> a
applyTwice f x = f (f x)

logged : String -> <Stdout> String
logged s =
  putStrLn "saw \{s}"
  s ++ "!"

main =
  println (applyTwice (n => n * 3) 2)
  println (applyTwice logged "hey")
```

```medaka-expect
18
saw hey
saw hey!
hey!!
```

The first call instantiates `e` to `<>`, so the whole expression is pure. The second
instantiates it to `<Stdout>`. Neither call needed a different `applyTwice`. This
is the same mechanism as the type variable `a`, applied to rows: the compiler
generalizes over effect variables when it generalizes over type variables, and
instantiates them fresh at each use.

`medaka check` prints the scheme as

```
applyTwice : (a -> <b> a) -> a -> <b> a
```

The variable you named `e` is shown as `b`. `check` renames every quantified
variable, type or effect, from one alphabet, so a letter in angle brackets is an
effect variable and the same letter outside them would be a type variable. The
names do not matter; what matters is that the two `<b>` are the same variable.

## Open rows

A function that does something of its own *and* runs a callback needs a row that
names both. The syntax is a tail after a bar:

```medaka
timed : String -> (Unit -> <e> a) -> <Clock, Stdout | e> a
timed label body =
  let t0 = monotonicSec ()
  let result = body ()
  let elapsed = monotonicSec () - t0
  if elapsed >= 0.0 then putStrLn "\{label}: done"
  result

main =
  let n = timed "sum" (() => sum [1..=100])
  println n
  timed "greet" (() => putStrLn "inside")
```

```medaka-expect
sum: done
5050
inside
greet: done
```

`<Clock, Stdout | e>` reads "Clock and Stdout, plus whatever `e` is". A row with a
tail is *open*; a row without one is *closed* and means exactly its labels. When
the callback is pure, `timed` performs `<Clock, Stdout>`. When it prints, the
`Stdout` is already there and the join is the same row. When it reads a file, the
`FileRead` rides along in `e`.

A row may have several tails when two callbacks are involved:

```medaka
both : (Unit -> <e> Unit) -> (Unit -> <e2> Unit) -> <e | e2> Unit
both f g =
  f ()
  g ()

main = both (() => putStrLn "one") (() => ePutStrLn "two")
```

```medaka-expect
one
```

(`two` goes to standard error, so it is not in the expected output.) Writing one
variable for both callbacks would also typecheck, since a single `e` can be
instantiated to the join of the two rows; two variables keep the two callbacks
independent in the type.

## A declared variable belongs to the caller

When a signature says `<e>`, the caller picks `e`. The body cannot decide that `e`
happens to include `Stdout`:

```medaka-nocheck: the program is refused, and the diagnostic is what the example is for
runQuietly : (Unit -> <e> a) -> <e> a
runQuietly body =
  putStrLn "running"
  body ()

main = println (runQuietly (() => 1))
```

```
error: poly.mdk:3:11: Binding 'runQuietly' performs <Stdout>, but the row it must fit, <a>, is chosen by its caller: a caller may instantiate that row to <> and would then run <Stdout> from a value typed pure. Declare <Stdout> in that row (write `<Stdout | a>` where the signature writes `<a>`), or perform it only through an argument whose row the caller sees.
  |
3 |   putStrLn "running"
  |            ^
```

The message spells out the fix. If `runQuietly` were accepted as written, a caller
passing a pure callback would get a value typed pure that prints. This is the rule
that makes effect variables trustworthy: an inferred variable in an unsigned
binding is solved by the body, but a variable you *declare* is rigid, and the body
has to fit it for every possible choice.

The same rule decides what a callback parameter lets you do. Taking an effectful
callback does not oblige you to call it, and not calling it costs nothing:

```medaka
describe : (Unit -> <e> Unit) -> String
describe _ = "a callback I never call"

callIt : (Unit -> <e> Unit) -> <e> Unit
callIt f = f ()

main =
  println (describe (() => putStrLn "never"))
  callIt (() => putStrLn "called")
```

```medaka-expect
a callback I never call
called
```

`describe` has a pure result row and accepts any callback, because a callback that
is never applied performs nothing. `callIt` applies it and so must carry `<e>` on
its own arrow. Declare `callIt : (Unit -> <e> Unit) -> Unit` instead and the
compiler points at the application:

```
error: poly.mdk:2:13: Binding 'callIt' runs the effect row <a>, which its caller chooses (an argument's or a callback's row), but only <> is allowed there: a caller may instantiate <a> to an effectful row and would then run it from a position typed <>. Declare that row at the arrow that runs it (write `-> <a> …`), or defer the value instead of running it.
  |
2 | callIt f = f ()
  |              ^
```

## Composition and pipes

Composing two functions joins their rows on the composed arrow. Constructing the
composition performs nothing; applying it performs both:

```medaka
trim : String -> String
trim s = s

announce : String -> <Stdout> String
announce s =
  putStrLn "announcing \{s}"
  s

pipeline : String -> <Stdout> String
pipeline = trim >> announce

main =
  let r = pipeline "x"
  println r
  ["a", "b"] |> map announce |> length |> println
```

```medaka-expect
announcing x
x
announcing a
announcing b
2
```

`trim >> announce` is a value of type `String -> <Stdout> String`, and binding it
to `pipeline` under that signature is fine. Binding it under `String -> String`
is not; the compiler refuses to let an alias or a composition drop a row, for the
same reason it refuses a body that performs more than its signature. `x |> f` is
just `f x` and performs `f`'s row right there.

The prelude's combinators all carry effect variables, so this works throughout:
`map`, `filter`, `any`, `all`, `find`, `count`, `option`, `result`, `flip`,
`compose`, `forEach`, `flatMap`, and the rest thread their callbacks' rows to their
own. A `do` block does too, since it desugars to `andThen`, which is why a
`Result`-returning function can print in the middle of a chain:

```medaka
import string.{toInt}

parseAge : String -> <Stdout> Result String Int
parseAge s = do
  n <- option (Err "not a number: \{s}") Ok (toInt s)
  let () = putStrLn "parsed \{n}"
  if n < 0 then Err "negative" else Ok n

main =
  println (parseAge "42")
  println (parseAge "x")
```

```medaka-expect
parsed 42
Ok 42
Err not a number: x
```

The `let () =` is how a `Unit`-valued effect goes in a `do` block, where a bare
statement would have to be a `Result`. The row of the block is the join of every
step.

## Interfaces

A method signature can carry an effect variable, and every `impl` is held to it the
same way a top-level signature is:

```medaka
interface Walkable t where
  walk : (a -> <e> Unit) -> t a -> <e> Unit

data Pair a = Pair a a

impl Walkable Pair where
  walk f (Pair x y) =
    f x
    f y

impl Walkable List where
  walk f xs = match xs
    [] => ()
    h :: t =>
      f h
      walk f t

main =
  walk println (Pair 1 2)
  walk (s => putStrLn "item \{s}") ["a", "b"]
```

```medaka-expect
1
2
item a
item b
```

An impl that printed something of its own would be refused, with the same message
as `runQuietly` above, because the interface promised `<e>` and a caller may pick
`<>`. Which impl is selected never changes the row a caller is charged; dispatch
is decided by types, and the row is decided by the signature.

## Callbacks in data

A field can hold a function, and its arrow carries a row like any other. Reading
the field is pure; applying what you read is charged:

```medaka
data Button = Button { label : String, onClick : Unit -> <Stdout> Unit }

press : Button -> <Stdout> Unit
press b =
  putStrLn "pressing \{b.label}"
  b.onClick ()

describe : Button -> String
describe b = "a button labelled \{b.label}"

main =
  let ok = Button { label = "OK", onClick = () => putStrLn "confirmed" }
  println (describe ok)
  press ok
```

```medaka-expect
a button labelled OK
pressing OK
confirmed
```

A field's row is a bound on what may be stored there. Storing a callback that
does more than the field declares is refused at the construction site, and the
same goes for a `Ref`:

```medaka-nocheck: the program is refused, and the diagnostic is what the example is for
main =
  let slot = Ref (() => ())
  slot := () => putStrLn "smuggled"
  let f = !slot
  f ()
```

```
error: poly.mdk:3:25: Effectful value used where <> is allowed, but it performs <Stdout>
  |
3 |   slot := () => putStrLn "smuggled"
  |                          ^
```

The cell was created holding a pure function, so its type is
`Ref (Unit -> <> Unit)`, and a cell's element type is invariant: a write must
match it exactly. Otherwise a pure-typed function read back from the cell could
print. If you want a cell that holds effectful callbacks, say so when you create
it:

```medaka
main =
  let slot = Ref (() => ()) : Ref (Unit -> <Stdout> Unit)
  slot := () => putStrLn "allowed"
  let f = !slot
  f ()
```

```medaka-expect
allowed
```

## Branches

The two arms of an `if` or the arms of a `match` may perform different rows; the
expression performs their join, and so does a recursive call:

```medaka
report : Bool -> <Stderr, Stdout> Unit
report ok = if ok then putStrLn "fine" else ePutStrLn "trouble"

loop : Int -> <Stdout> Unit
loop 0 = ()
loop n =
  putStrLn "tick \{n}"
  loop (n - 1)

main =
  report True
  loop 2
```

```medaka-expect
fine
tick 2
tick 1
```

Nothing here needed a variable. Variables are for the case where a row depends on
an argument; when every row in sight is concrete, joins are all the compiler needs.

With this much you can read every effect signature in the standard library. The
next chapter leaves the built-in vocabulary and declares labels of your own.
