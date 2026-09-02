# validation

## `Validation`

```
data Validation e a
  = Failure e
  | Success a
```

Instances: `Mappable`, [`Applicative`](#applicative-validation-e), `Foldable`, `Traversable`, `Eq`, `Debug`, [`Semigroup`](#semigroup-validation-e-a), [`Display`](#display-validation-e-a)

Validation's own `Failure`/`Success` — same shape as `Result`'s
`Err`/`Ok`, distinguished by name so its different `Applicative` reads
as intentional rather than a `Result` look-alike bug.

```medaka
> toResult (Success 1)
Ok 1
> toResult (Failure "bad")
Err "bad"
```

## `toResult`

```
toResult : Validation e a -> Result e a
```

Drop down to the short-circuiting `Result` (e.g. to `andThen`-sequence
once you no longer need to accumulate).

```medaka
> toResult (Success 1)
Ok 1
```

## `fromResult`

```
fromResult : Result e a -> Validation e a
```

Lift a `Result` into `Validation` (e.g. to combine it with others via
the accumulating `Applicative`).

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

The accumulating `Applicative`. `pure` lifts into `Success`; `ap`
combines two `Failure`s with `Semigroup e`'s `++` instead of keeping only
the first, so validating several fields collects every error.

```medaka
> toResult (ap (Failure ["bad name"] : Validation (List String) (Int -> Int)) (Failure ["bad age"] : Validation (List String) Int))
Err ["bad name", "bad age"]
> toResult (ap (Failure ["bad name"] : Validation (List String) (Int -> Int)) (Success 5 : Validation (List String) Int))
Err ["bad name"]
> toResult (ap (pure (n => n + 1) : Validation (List String) (Int -> Int)) (Success 5 : Validation (List String) Int))
Ok 6
```

### `Semigroup (Validation e a)`

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

```medaka
> display (append (Failure ["a"] : Validation (List String) (List Int)) (Failure ["b"]))
"Failure [a, b]"
> display (append (Success [1] : Validation (List String) (List Int)) (Success [2]))
"Success [1, 2]"
> display (append (Failure ["a"] : Validation (List String) (List Int)) (Success [2]))
"Failure [a]"
```

### `Display (Validation e a)`

```
impl Display (Validation e a) requires Display e, Display a
```

Human-facing rendering (backs `println` and `\{}` interpolation), mirroring
core's `Display (Result e a)`.

```medaka
> display (Success 7)
"Success 7"
> display (Failure "bad")
"Failure bad"
```

