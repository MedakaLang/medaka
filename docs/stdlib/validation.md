# validation

validation.mdk — an accumulating-error applicative.

`Validation e a` is shaped exactly like `Result e a` (`Failure`/`Success`
instead of `Err`/`Ok`) but its `Applicative` has different semantics:
`Result`'s `ap` short-circuits on the first `Err`, while `Validation`'s
`ap` COMBINES both sides' errors via `Semigroup e` when both are
`Failure`. This is the standard shape used to validate several
independent fields of a record and report every problem at once, rather
than just the first one.

Deliberately NO `impl Thenable Validation`. A monadic `andThen` must
short-circuit — the second computation only runs (and so its error only
exists) once the first succeeds — which is exactly the opposite of the
accumulating `Applicative` above. Offering both on the same type would
be incoherent (two "correct" answers for combining two failures depend
on which interface a caller happens to reach for). Haskell's
`validation` package, PureScript, and Scala/cats' `Validated` all make
this same call: accumulate via `Applicative`, and if you need
short-circuiting sequencing, convert to `Result` (`validationToResult`) first.

## `Validation`

```
data Validation e a
  = Failure e
  | Success a
```

Validation's own `Failure`/`Success` — same shape as `Result`'s
`Err`/`Ok`, distinguished by name so its different `Applicative` reads
as intentional rather than a `Result` look-alike bug.


*(doctest — run by `medaka test`)*

```medaka
> validationToResult (Success 1)
Ok 1
> validationToResult (Failure "bad")
Err "bad"
```

## `Mappable (Validation e)`

```
impl Mappable (Validation e)
```

## `Applicative (Validation e)`

```
impl Applicative (Validation e) requires Semigroup e
```

The accumulating `Applicative`. `pure` lifts into `Success`; `ap`
combines two `Failure`s with `Semigroup e`'s `++` instead of keeping only
the first, so validating several fields collects every error.


*(doctest — run by `medaka test`)*

```medaka
> validationToResult (ap (Failure ["bad name"] : Validation (List String) (Int -> Int)) (Failure ["bad age"] : Validation (List String) Int))
Err ["bad name", "bad age"]
> validationToResult (ap (Failure ["bad name"] : Validation (List String) (Int -> Int)) (Success 5 : Validation (List String) Int))
Err ["bad name"]
> validationToResult (ap (pure (n => n + 1) : Validation (List String) (Int -> Int)) (Success 5 : Validation (List String) Int))
Ok 6
```

## `Foldable (Validation e)`

```
impl Foldable (Validation e)
```

## `Traversable (Validation e)`

```
impl Traversable (Validation e)
```

Multi-clause + return-position `pure` loops in eval for Thenable impls;
see the note above core.mdk's Traversable impls — do not split.
lint-disable-next-line rule-match-on-param

## `Eq (Validation e a)`

```
impl Eq (Validation e a) requires Eq e, Eq a
```

## `Debug (Validation e a)`

```
impl Debug (Validation e a) requires Debug e, Debug a
```

## `Display (Validation e a)`

```
impl Display (Validation e a) requires Display e, Display a
```

Human-facing rendering (backs `println` and `\{}` interpolation), mirroring
core's `Display (Result e a)`.


*(doctest — run by `medaka test`)*

```medaka
> display (Success 7)
"Success 7"
> display (Failure "bad")
"Failure bad"
```

## `validationToResult`

```
validationToResult : Validation a b -> Result a b
```

Drop down to the short-circuiting `Result` (e.g. to `andThen`-sequence
once you no longer need to accumulate).


*(doctest — run by `medaka test`)*

```medaka
> validationToResult (Success 1)
Ok 1
```

## `resultToValidation`

```
resultToValidation : Result a b -> Validation a b
```

Lift a `Result` into `Validation` (e.g. to combine it with others via
the accumulating `Applicative`).


*(doctest — run by `medaka test`)*

```medaka
> resultToValidation (Ok 1 : Result String Int)
Success 1
> resultToValidation (Err "bad" : Result String Int)
Failure "bad"
```

