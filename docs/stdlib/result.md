# result

result.mdk — the `Result` eliminator.

`Result e a` (`Ok`/`Err`) itself lives in `core.mdk` (the implicit
prelude), alongside `isOk`/`isErr`/`fromResultOr`/`mapErr`.  This module
adds the one thing core doesn't: the fold-both-cases eliminator, named
`result` (Haskell calls it `either`, but Medaka names a thing for what it
eliminates, not for category theory — it matches the `Result` type).

## `result`

```
result : (a -> b) -> (c -> b) -> Result a c -> b
```

Eliminate a `Result` by supplying a handler for `Err` and a handler for
`Ok`.


*(doctest — run by `medaka test`)*

```medaka
> result (e => 0) (x => x + 1) (Ok 41)
42
> result (e => e) (x => x + 1) (Err 7)
7
```

