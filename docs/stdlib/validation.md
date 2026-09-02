# validation

A result type that collects every error instead of stopping at the
first.

`Validation e a` has the same shape as `Result e a`, with `Failure` and
`Success` in place of `Err` and `Ok`. Its `Applicative` instance
combines the errors of two failures with `++`, so validating several
independent fields reports every problem at once. Convert with
`toResult` and `fromResult`.

There is no `Thenable` instance: sequencing with `andThen` has to stop
at the first failure, which is the opposite of accumulating. To
sequence, convert to a `Result` first.

`toResult` and `fromResult` share their names with prelude functions on
`Option`. Import this module qualified, `import validation as V`, and
write `V.toResult`.

## `Validation`

```
data Validation e a
  = Failure e
  | Success a
```

A validated value: `Success` with the value, or `Failure` with the
accumulated errors.

```medaka
> toResult (Success 1)
Ok 1
> toResult (Failure "bad")
Err "bad"
```

Instances: `Mappable`, [`Applicative`](#applicative-validation-e), `Foldable`, `Traversable`, `Eq`, `Debug`, [`Semigroup`](#semigroup-validation-e-a), [`Display`](#display-validation-e-a)

## `toResult`

```
toResult : Validation e a -> Result e a
```

The validation as a `Result`, for sequencing with `andThen`.

```medaka
> toResult (Success 1)
Ok 1
```

## `fromResult`

```
fromResult : Result e a -> Validation e a
```

A `Result` as a validation, for combining with others.

```medaka
> fromResult (Ok 1 : Result String Int)
Success 1
> fromResult (Err "bad" : Result String Int)
Failure "bad"
```

## Instances

### `Applicative (Validation e)`

```
impl Applicative (Validation e) requires Semigroup e
```

`ap` combines the errors of two failures with `++`, so a chain of
validations collects every error.

```medaka
> toResult (ap (Failure ["bad name"] : Validation (List String) (Int -> Int)) (Failure ["bad age"] : Validation (List String) Int))
Err ["bad name", "bad age"]
```

### `Semigroup (Validation e a)`

```
impl Semigroup (Validation e a) requires Semigroup e, Semigroup a
```

`++` combines two failures' errors, combines two successes' values,
and keeps the failure when there is one of each.

There is no `Monoid` instance, since no value is an identity on both
sides.

```medaka
> display (append (Failure ["a"] : Validation (List String) (List Int)) (Failure ["b"]))
"Failure [a, b]"
> display (append (Success [1] : Validation (List String) (List Int)) (Success [2]))
"Success [1, 2]"
```

### `Display (Validation e a)`

```
impl Display (Validation e a) requires Display e, Display a
```

`display` renders a value as `Success x` or `Failure e`.

```medaka
> display (Success 7)
"Success 7"
> display (Failure "bad")
"Failure bad"
```

