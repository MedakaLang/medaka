# gamma

gamma.mdk — library-mode fixture module #3: S-doc-surface-truth hole (b).
Declares an interface plus a type of its own, and writes two impls whose
pages differ: `Sizeish Widget` stays here (this module DECLARES `Widget` —
ownership clause 1), while `Sizeish (Array Int)` is re-filed onto the
`array` page (clause 2: `Array` is an opaque builtin declared nowhere, and
the library set contains a module named for it) — exactly how the real
`stdlib/core.mdk` loses `Debug (Array a)` to `stdlib/array.mdk`.

## `Widget`

```
data Widget
  = Widget Int
```

A tiny type declared HERE.

## `Sizeish`

```
interface Sizeish a
  sizeOf : a -> Int
```

Anything with a size.

## `Sizeish Widget`

```
impl Sizeish Widget
```

Stays on `gamma`: gamma declares `Widget`.

