# array

array.mdk — library-mode fixture module #4: a module NAMED for an opaque
builtin.  It declares nothing about `Array`; it only has to EXIST under that
name for `rebucketLibraryImpls`' ownership clause 2 to file gamma's
`Sizeish (Array Int)` here.

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

