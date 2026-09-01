# nonempty

nonempty — a guaranteed-non-empty list.

`NonEmpty a` is a head element plus a (possibly empty) tail list, so it can
never be empty by construction.  This lets `head`, `maximum`, and `minimum`
be TOTAL — they return an `a`, not an `Option a` like the partial Foldable
helpers on a plain `List`.

Import by bare name: `import nonempty` (this module is not auto-prelude), then
call `nonempty.head`, `nonempty.maximum`, etc.

## `NonEmpty`

```
data NonEmpty a
  = NECons a (List a)
```

A head element plus a (possibly empty) tail.  Never empty.

## `singleton`

```
singleton : a -> NonEmpty a
```

A `NonEmpty` holding exactly one element.


*(doctest — run by `medaka test`)*

```medaka
> toList (singleton 9)
[9]
> head (singleton 9)
9
```

## `fromList`

```
fromList : List a -> Option (NonEmpty a)
```

Build a `NonEmpty` from a plain list, or `None` if the list is empty.
Inverse of `toList` for non-empty inputs.


*(doctest — run by `medaka test`)*

```medaka
> fromList [1, 2, 3] == Some (NECons 1 [2, 3])
True
> fromList ([] : List Int)
None
```

## `head`

```
head : NonEmpty a -> a
```

The first element.  Total (a `NonEmpty` always has one).


*(doctest — run by `medaka test`)*

```medaka
> head (NECons 7 [8, 9])
7
```

## `maximum`

```
maximum : Ord a => NonEmpty a -> a
```

The largest element.  Total.


*(doctest — run by `medaka test`)*

```medaka
> maximum (NECons 3 [1, 4, 1, 5])
5
```

## `minimum`

```
minimum : Ord a => NonEmpty a -> a
```

The smallest element.  Total.


*(doctest — run by `medaka test`)*

```medaka
> minimum (NECons 3 [1, 4, 1, 5])
1
```

## `Mappable NonEmpty`

```
impl Mappable NonEmpty
```

Map over every element, preserving non-emptiness.


*(doctest — run by `medaka test`)*

```medaka
> toList (map (n => n * 2) (NECons 1 [2, 3]))
[2, 4, 6]
```

## `Foldable NonEmpty`

```
impl Foldable NonEmpty
```

Fold over every element (head first).  `toList` recovers the plain list.


*(doctest — run by `medaka test`)*

```medaka
> fold (acc y => acc + y) 0 (NECons 1 [2, 3])
6
> toList (NECons 1 [2, 3])
[1, 2, 3]
```

## `Traversable NonEmpty`

```
impl Traversable NonEmpty
```

## `Semigroup (NonEmpty a)`

```
impl Semigroup (NonEmpty a)
```

Append concatenates: the head of the left operand, then everything else.


*(doctest — run by `medaka test`)*

```medaka
> toList (append (NECons 1 [2]) (NECons 3 [4]))
[1, 2, 3, 4]
```

## `Eq (NonEmpty a)`

```
impl Eq (NonEmpty a) requires Eq a
```

## `Debug (NonEmpty a)`

```
impl Debug (NonEmpty a) requires Debug a
```

## `Display (NonEmpty a)`

```
impl Display (NonEmpty a) requires Display a
```

Human-facing rendering (backs `println` and `\{}` interpolation).


*(doctest — run by `medaka test`)*

```medaka
> display (NECons 1 [2, 3])
"NonEmpty [1, 2, 3]"
```

