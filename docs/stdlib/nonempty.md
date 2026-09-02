# nonempty

## `NonEmpty`

```
data NonEmpty a
  = NECons a (List a)
```

Instances: [`Mappable`](#mappable-nonempty), [`Foldable`](#foldable-nonempty), `Traversable`, [`Semigroup`](#semigroup-nonempty-a), `Eq`, `Debug`, [`Display`](#display-nonempty-a)

## `singleton`

```
singleton : a -> NonEmpty a
```

A `NonEmpty` holding exactly one element.

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

```medaka
> head (NECons 7 [8, 9])
7
```

## `maximum`

```
maximum : Ord a => NonEmpty a -> a
```

The largest element.  Total.

```medaka
> maximum (NECons 3 [1, 4, 1, 5])
5
```

## `minimum`

```
minimum : Ord a => NonEmpty a -> a
```

The smallest element.  Total.

```medaka
> minimum (NECons 3 [1, 4, 1, 5])
1
```

## Instances

### `Mappable NonEmpty`

```
impl Mappable NonEmpty
```

Map over every element, preserving non-emptiness.

```medaka
> toList (map (n => n * 2) (NECons 1 [2, 3]))
[2, 4, 6]
```

### `Foldable NonEmpty`

```
impl Foldable NonEmpty
```

Fold over every element (head first).  `toList` recovers the plain list.

```medaka
> fold (acc y => acc + y) 0 (NECons 1 [2, 3])
6
> toList (NECons 1 [2, 3])
[1, 2, 3]
```

### `Semigroup (NonEmpty a)`

```
impl Semigroup (NonEmpty a)
```

Append concatenates: the head of the left operand, then everything else.

```medaka
> toList (append (NECons 1 [2]) (NECons 3 [4]))
[1, 2, 3, 4]
```

### `Display (NonEmpty a)`

```
impl Display (NonEmpty a) requires Display a
```

Human-facing rendering (backs `println` and `\{}` interpolation).

```medaka
> display (NECons 1 [2, 3])
"NonEmpty [1, 2, 3]"
```

