# array

array.mdk — library-mode fixture module #4: a module NAMED for an opaque
builtin.  It DECLARES nothing about `Array` (no `data`/`newtype`), so
ownership clause 1 cannot reach it; clause 2 files gamma's
`Sizeish (Array Int)` here because this module is named for the type AND
corroborates that by naming `Array` in its own signature below.  (S2-1: the
corroboration is required — `test/doc_fixtures/library/gadget.mdk` is the
negative control, a module named for a type it never mentions.)

## `firstOrZero`

```
firstOrZero : Array Int -> Int
```

First element, or 0 for an empty array.

## `Sizeish (Array Int)`

```
impl Sizeish (Array Int)
```

Moves to `array`: `Array` has no declaring module in the set.

