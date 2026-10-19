# canvas_host

Scalar browser bindings for rendering pure pictures.

A browser host must supply the versioned canvas bindings. Calls belong
inside one entry invocation; begin precedes frame reads and rendering.

## `begin`

```
begin : Bool -> <FFI "js/canvas"> Unit
```

Begin the invocation's picture, requesting further frames when true.

## `elapsed`

```
elapsed : Unit -> <FFI "js/canvas"> Float
```

Active animation time in seconds.

## `delta`

```
delta : Unit -> <FFI "js/canvas"> Float
```

Seconds since the previous delivered frame, clamped by the host.

## `width`

```
width : Unit -> <FFI "js/canvas"> Float
```

Logical viewport width in CSS pixels.

## `height`

```
height : Unit -> <FFI "js/canvas"> Float
```

Logical viewport height in CSS pixels.

## `pointerX`

```
pointerX : Unit -> <FFI "js/canvas"> Float
```

Horizontal pointer position relative to the canvas center.

## `pointerY`

```
pointerY : Unit -> <FFI "js/canvas"> Float
```

Vertical pointer position, increasing upward.

## `pointerInside`

```
pointerInside : Unit -> <FFI "js/canvas"> Bool
```

Whether the pointer lies inside the canvas.

## `pointerDown`

```
pointerDown : Unit -> <FFI "js/canvas"> Bool
```

Whether the primary pointer is pressed.

## `render`

```
render : Picture -> <FFI "js/canvas"> Unit
render scene
```

Render a complete picture after begin and seal its command batch.

The host validates every scalar, including degenerate shapes, and presents
the batch only after the guest invocation returns successfully.
