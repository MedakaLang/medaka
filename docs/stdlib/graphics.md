# graphics

Pure pictures in logical canvas coordinates.

The origin is at the viewport center, with x right and y up. Constructors
preserve their arguments; the canvas host validates a whole frame before
presenting it.

## `Point`

```
data Point
  = Point { x : Float, y : Float }
```

A position measured in logical CSS pixels.

Instances: `Eq`, `Debug`

## `Color`

```
data Color
  = Color { red : Float, green : Float, blue : Float, alpha : Float }
```

Straight RGBA components in the range zero through one.

Instances: `Eq`, `Debug`

## `Shape`

```
data Shape
  = Line Color Float Point Point
  | Circle Color Point Float
  | Polygon Color (List Point)
```

A stroked line, filled circle, or filled polygon.

Zero-radius circles and polygons with fewer than three points paint
nothing. Line widths must be positive; radii must be nonnegative.

Instances: `Eq`, `Debug`

## `Picture`

```
data Picture
  = Picture { background : Color, shapes : List Shape }
```

A complete frame, painted in list order over its background.

Transparent backgrounds clear the preceding frame before painting.

Instances: `Eq`, `Debug`

## `point`

```
point : Float -> Float -> Point
point x y
```

A point at the given horizontal and vertical coordinates.

```medaka
> point 3.0 4.0
Point { x = 3.0, y = 4.0 }
```

## `rgba`

```
rgba : Float -> Float -> Float -> Float -> Color
rgba red green blue alpha
```

A color with the given red, green, blue, and alpha components.

Values are preserved, including components outside the host's valid range.

```medaka
> rgba 1.0 0.5 0.0 1.0
Color { red = 1.0, green = 0.5, blue = 0.0, alpha = 1.0 }
```

## `line`

```
line : Color -> Float -> Point -> Point -> Shape
line color width from to
```

A line whose width uses logical CSS pixels.

```medaka
> line (rgba 1.0 0.0 0.0 1.0) 2.0 (point 0.0 0.0) (point 5.0 5.0)
Line (Color { red = 1.0, green = 0.0, blue = 0.0, alpha = 1.0 }) 2.0 (Point { x = 0.0, y = 0.0 }) (Point { x = 5.0, y = 5.0 })
```

## `circle`

```
circle : Color -> Point -> Float -> Shape
circle color center radius
```

A filled circle whose radius uses logical CSS pixels.

```medaka
> circle (rgba 0.0 0.5 1.0 1.0) (point 2.0 3.0) 4.0
Circle (Color { red = 0.0, green = 0.5, blue = 1.0, alpha = 1.0 }) (Point { x = 2.0, y = 3.0 }) 4.0
```

## `polygon`

```
polygon : Color -> List Point -> Shape
polygon color points
```

A filled polygon whose final point connects to its first point.

```medaka
> polygon (rgba 0.0 1.0 0.0 1.0) [point 0.0 0.0, point 4.0 0.0, point 2.0 3.0]
Polygon (Color { red = 0.0, green = 1.0, blue = 0.0, alpha = 1.0 }) [Point { x = 0.0, y = 0.0 }, Point { x = 4.0, y = 0.0 }, Point { x = 2.0, y = 3.0 }]
```

## `picture`

```
picture : Color -> List Shape -> Picture
picture background shapes
```

A complete picture with shapes painted in their supplied order.

```medaka
> picture (rgba 0.0 0.0 0.0 1.0) [circle (rgba 1.0 1.0 1.0 1.0) (point 0.0 0.0) 2.0]
Picture { background = Color { red = 0.0, green = 0.0, blue = 0.0, alpha = 1.0 }, shapes = [Circle (Color { red = 1.0, green = 1.0, blue = 1.0, alpha = 1.0 }) (Point { x = 0.0, y = 0.0 }) 2.0] }
```
