# gamma

## `Widget`

```
data Widget
  = Widget Int
```

A tiny type declared HERE.

Instances: [`Sizeish`](#sizeish-widget)

## `Sizeish`

```
interface Sizeish a
  sizeOf : a -> Int
```

Anything with a size.

## Instances

### `Sizeish Widget`

```
impl Sizeish Widget
```

Stays on `gamma`: gamma declares `Widget`.

