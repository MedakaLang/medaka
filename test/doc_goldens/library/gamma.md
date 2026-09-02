# gamma

## `Widget`

```
data Widget
  = Widget Int
```

Instances: [`Sizeish`](#sizeish-widget)

A tiny type declared HERE.

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

