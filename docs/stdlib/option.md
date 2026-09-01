# option

option.mdk — the `Option` eliminator.

`Option a` (`Some`/`None`) itself lives in `core.mdk` (the implicit
prelude), alongside `isSome`/`isNone`/`fromOption`/`toResult`/`fromResult`.
This module adds the one thing core doesn't: the fold-both-cases
eliminator, named `option` (Haskell calls it `maybe`, but Medaka names a
thing for what it eliminates, not for category theory — it matches the
`Option` type).

## `option`

```
option : a -> (b -> a) -> Option b -> a
```

Eliminate an `Option` by supplying a default for `None` and a function
for `Some`.


*(doctest — run by `medaka test`)*

```medaka
> option 0 (x => x + 1) (Some 41)
42
> option 0 (x => x + 1) None
0
```

