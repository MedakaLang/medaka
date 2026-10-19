# animation

Pictures driven by browser frames and retained simulation models.

Bind a simulation once at module scope to retain its model across frames.
Constructing one inside main creates a fresh model on every invocation.

## `Pointer`

```
data Pointer
  = Pointer { x : Float, y : Float, inside : Bool, down : Bool }
```

The primary pointer in logical canvas coordinates.

Instances: `Eq`, `Debug`

## `Frame`

```
data Frame
  = Frame { elapsed : Float, delta : Float, width : Float, height : Float, pointer : Pointer }
```

An immutable snapshot for one delivered frame.

Times are seconds of active animation; width and height are CSS pixels.
Delta is zero on the first frame and after resuming, otherwise at most 0.05.

Instances: `Eq`, `Debug`

## `Simulation`

```
data Simulation model  -- abstract: the constructors are not exported
```

A retained model with pure update and view functions.

## `drawing`

```
drawing : Picture -> <FFI "js/canvas"> Unit
drawing scene
```

Draw one picture and finish without requesting another frame.

## `animate`

```
animate : (Float -> Picture) -> <FFI "js/canvas"> Unit
animate scene
```

Draw a pure scene function of elapsed seconds on each frame.

## `animateWith`

```
animateWith : (Frame -> Picture) -> <FFI "js/canvas"> Unit
animateWith scene
```

Draw a pure scene function with viewport and pointer input.

## `simulation`

```
simulation : model -> (Frame -> model -> model) -> (Frame -> model -> Picture) -> Simulation model
simulation initial update view
```

Capture an initial model and pure update and view functions.

Construction makes no host call and does not invoke either callback.

## `runSimulation`

```
runSimulation : Simulation model -> <FFI "js/canvas"> Unit
```

Render the initial model, then update once before each later view.

Call from main with a simulation retained at module scope. Other effects
in main repeat on each delivered frame too.
