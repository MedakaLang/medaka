# Canvas Animation in the Playground

Choose **cube**, **lissajous**, or **balls** in the playground's examples picker,
then press **Run**. Each example is a complete editable Medaka program. **Share**
saves that source in the URL, including your edits.

The cube demonstrates rotation and perspective with eight vertices and twelve
edges. Move the pointer over its canvas to change the rotation offset. The
Lissajous example draws a curve from a list of trigonometric samples. The balls
example keeps a model between frames, bounces against the walls, and accelerates
toward the primary pointer while you hold it down.

## A picture for each time

`graphics` describes a complete picture: a background followed by lines, circles,
or filled polygons in drawing order. The origin is the canvas center; x increases
to the right and y increases upward. Coordinates and sizes use CSS pixels. Color
components range from zero to one.

The playground supplies `graphics`, `canvas_host`, and `animation` for this
browser feature. They are playground modules, not standard-library modules.

This program runs in the playground's canvas host:

```medaka
import animation.{animate}
import graphics.{Color(..), Picture(..), Point(..), Shape(..)}

scene : Float -> Picture
scene seconds =
  Picture {
    background = Color { red = 0.02, green = 0.04, blue = 0.08, alpha = 1.0 },
    shapes = [Circle (Color { red = 0.3, green = 0.85, blue = 1.0, alpha = 1.0 })
      (Point { x = 80.0 * sin seconds, y = 0.0 }) 20.0],
  }

main = animate scene
```

`animate` supplies elapsed seconds of active animation. `animateWith` supplies a
`Frame` containing elapsed time, delta, viewport width and height, and the primary
pointer's `x`, `y`, `inside`, and `down` fields. The pointer uses the same centered
coordinates as the picture. Use `drawing` for a static picture.

## Retaining a model

The balls source separates `initial`, `update`, and `view`. `simulation initial
update view` captures the model, and `runSimulation app` presents it. Bind `app`
at module scope: constructing it inside `main` would start over each frame.
The first frame renders the initial model; each later frame updates once before
rendering. A fresh **Run** creates a fresh model.

Updates receive a delta in seconds, capped at 0.05. Multiply speed by delta so
motion follows elapsed time across different frame rates. Delta is zero on the
first frame and after resuming. Keep scene, update, and view functions pure;
the animation adapter performs the canvas effect. The canvas bindings require
the browser host and cannot render through a native command-line run.

## Controlling a run

**Pause** holds the current image and active clock; **Resume** continues.
**Stop** terminates the runner and retains its last image. **Run** compiles the
current editor source into a new runner. Switching to a background tab suspends
the animation, and returning preserves a manual pause. A reduced-motion
preference starts with a still first frame and an explicit **Resume** control.

The canvas resizes with the page. Each picture replaces the preceding picture,
including a transparent background, so draw everything that should remain
visible in every frame. The host bounds picture size and frame work; a failed
frame leaves the last complete image visible and reports an error in the console.
