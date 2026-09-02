# nonempty

A list with at least one element.

`NonEmpty a` is a first element and a tail, so it cannot be empty. That
makes `head`, `maximum`, and `minimum` total: they return the element
itself rather than an `Option`. Build one with `singleton`, `fromList`,
or the `NECons` constructor.

Import the module by name, `import nonempty`, and call `nonempty.head`
and the rest qualified, since the names overlap with `list`'s.

### `NonEmpty`

```
data NonEmpty a
  = NECons a (List a)
```

A first element and the rest of the list.

Instances: [`Mappable`](#mappable-nonempty), [`Foldable`](#foldable-nonempty), `Traversable`, [`Semigroup`](#semigroup-nonempty-a), `Eq`, `Debug`, [`Display`](#display-nonempty-a)

## Construction

### `singleton`

```
singleton : a -> NonEmpty a
```

A list holding one element.

```medaka
> toList (singleton 9)
[9]
```

### `fromList`

```
fromList : List a -> Option (NonEmpty a)
```

A non-empty list holding the elements of a list, or `None` when the
list is empty.

The inverse of `toList`.

```medaka
> fromList [1, 2, 3]
Some NonEmpty [1, 2, 3]
> fromList ([] : List Int)
None
```

## Accessing elements

### `head`

```
head : NonEmpty a -> a
```

The first element.

```medaka
> head (NECons 7 [8, 9])
7
```

### `maximum`

```
maximum : Ord a => NonEmpty a -> a
```

The largest element.

```medaka
> maximum (NECons 3 [1, 4, 1, 5])
5
```

### `minimum`

```
minimum : Ord a => NonEmpty a -> a
```

The smallest element.

```medaka
> minimum (NECons 3 [1, 4, 1, 5])
1
```

## Instances

### `Mappable NonEmpty`

```
impl Mappable NonEmpty
```

`map` applies a function to every element.

```medaka
> toList (map (n => n * 2) (NECons 1 [2, 3]))
[2, 4, 6]
```

### `Foldable NonEmpty`

```
impl Foldable NonEmpty
```

The `Foldable` methods visit the elements in order, first element
first. `toList` gives back the plain list.

```medaka
> toList (NECons 1 [2, 3])
[1, 2, 3]
```

### `Semigroup (NonEmpty a)`

```
impl Semigroup (NonEmpty a)
```

`++` concatenates two non-empty lists.

```medaka
> toList (append (NECons 1 [2]) (NECons 3 [4]))
[1, 2, 3, 4]
```

### `Display (NonEmpty a)`

```
impl Display (NonEmpty a) requires Display a
```

`display` renders a non-empty list as `NonEmpty [x, ...]`.

```medaka
> display (NECons 1 [2, 3])
"NonEmpty [1, 2, 3]"
```

