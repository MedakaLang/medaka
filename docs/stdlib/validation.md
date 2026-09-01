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
short-circuiting sequencing, convert to `Result` (`toResult`) first.

⚠️ `toResult` and `fromResult` (renamed from `validationToResult`/
`resultToValidation` by #2306 D-2, so the module qualifier carries the type
instead of the name stuttering it) DELIBERATELY reuse two prelude spellings:
`core.toResult : e -> Option a -> Result e a` and `core.fromResult :
Result e a -> Option a`.  A selective `import validation.{toResult}` SHADOWS
the prelude name in that module with no ambiguity diagnostic, so prefer
`import validation as V` and write `V.toResult`.

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
> toResult (Success 1)
Ok 1
> toResult (Failure "bad")
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
> toResult (ap (Failure ["bad name"] : Validation (List String) (Int -> Int)) (Failure ["bad age"] : Validation (List String) Int))
Err ["bad name", "bad age"]
> toResult (ap (Failure ["bad name"] : Validation (List String) (Int -> Int)) (Success 5 : Validation (List String) Int))
Err ["bad name"]
> toResult (ap (pure (n => n + 1) : Validation (List String) (Int -> Int)) (Success 5 : Validation (List String) Int))
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

## `Semigroup (Validation e a)`

```
impl Semigroup (Validation e a) requires Semigroup e, Semigroup a
```

The accumulating `Semigroup` (sheet row A-5), agreeing with the
`Applicative` above: two `Failure`s combine their errors rather than
keeping the first, so `append` never loses a diagnostic.  Two `Success`es
combine their payloads, which is why `Semigroup a` is required as well as
`Semigroup e` -- without it there is no answer for `Success <> Success`
and the instance would have to invent one.

No `Monoid` peer: an identity would have to be a `Success empty` that also
annihilates a `Failure`, and it does not (`Failure e ++ Success empty` is
`Failure e`, not `Success empty`), so the identity law fails on one side.


*(doctest — run by `medaka test`)*

```medaka
> display (append (Failure ["a"] : Validation (List String) (List Int)) (Failure ["b"]))
"Failure [a, b]"
> display (append (Success [1] : Validation (List String) (List Int)) (Success [2]))
"Success [1, 2]"
> display (append (Failure ["a"] : Validation (List String) (List Int)) (Success [2]))
"Failure [a]"
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

## `toResult`

```
toResult : Validation a b -> Result a b
```

Drop down to the short-circuiting `Result` (e.g. to `andThen`-sequence
once you no longer need to accumulate).


*(doctest — run by `medaka test`)*

```medaka
> toResult (Success 1)
Ok 1
```

## `fromResult`

```
fromResult : Result a b -> Validation a b
```

Lift a `Result` into `Validation` (e.g. to combine it with others via
the accumulating `Applicative`).


*(doctest — run by `medaka test`)*

```medaka
> fromResult (Ok 1 : Result String Int)
Success 1
> fromResult (Err "bad" : Result String Int)
Failure "bad"
```

