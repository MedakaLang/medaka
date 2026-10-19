# Playground canvas and animation

**Status:** IMPLEMENTED — the playground examples and API are available; see the [user guide](../../docs/advanced/playground-animation.md).

Planning base: `31f730fa4b186424d919e1d469e6cc64e95a40b5` (2026-10-19).
Tracking: [#4328](https://github.com/MedakaLang/medaka/issues/4328).
Execution order, ownership, and acceptance are in
[the implementation plan](PLAYGROUND-ANIMATION-PLAN.md).
This document records the implemented behavior and its boundaries.

## 1. Outcome and scope

A visitor selects a rotating-cube example, edits ordinary Medaka, presses Run,
and sees a canvas alongside the console. Geometry, animation, and simulation
execute as compiled WasmGC in the runner worker. JavaScript schedules work and
interprets a bounded drawing vocabulary. The same library and host adapter can
be embedded outside the playground without the editor or browser compiler.

The first release includes static pictures, pure animations, stateful simulations,
pointer input, resizing, Pause/Resume, Stop, and three editable examples. It uses
Canvas 2D. General DOM access, arbitrary JavaScript evaluation, image/network
assets, keyboard subscriptions, audio, WebGL/WebGPU, and a scene graph with
incremental diffing are outside this release. They add unrelated resource or
interaction contracts. OffscreenCanvas is a possible later renderer, contingent
on measurement. Foreign exports and closure callbacks are a separately designed
fallback if the execution spike disproves this proposal.

## 2. Precedents and selected approach

| Precedent | Evidence | Decision for Medaka |
|---|---|---|
| Hoot uses a small Scheme Canvas binding and JavaScript imports in its game template. | [Maintainer explanation and template links](https://community.spritely.institute/t/using-game-libraries-with-hoot-like-phaser-or-three-js/776) | Implement browser operations as library bindings. |
| Wasm_of_ocaml supports js_of_ocaml libraries and Canvas-backed Graphics. | [Wasm_of_ocaml manual](https://ocaml.org/p/js_of_ocaml/6.4.1/doc/wasm_overview.html) | Keep the language/compiler independent of drawing APIs. |
| GHC WASM offers static exports and dynamic closure wrappers, with retention and release rules. | [GHC WASM foreign exports](https://ghc.gitlab.haskell.org/ghc/doc/users_guide/wasm.html#foreign-exports) | Do not casually add callbacks to the scalar FFI. |
| Elm, a JavaScript-targeting precedent, exposes animation ticks as subscriptions. | [Browser.Events](https://github.com/elm/browser/blob/master/src/Browser/Events.elm) | Offer pure time-to-picture and model/update/view APIs. |

These precedents support the division of responsibilities, not a claim that they
use Medaka's proposed worker protocol. That protocol is our adaptation to the
existing playground. Browser scheduling uses
[requestAnimationFrame](https://developer.mozilla.org/en-US/docs/Web/API/Window/requestAnimationFrame),
whose timestamps avoid refresh-rate-dependent animation speed.

## 3. Architecture and ownership

```text
editor -> compiler worker -> user WASM bytes
                                  |
page scheduler -- frame inputs --> runner worker / persistent WASM instance
                                  |
                                  +-- pure Medaka scene/update functions
                                  +-- scalar JS FFI -> worker-local command buffer
                                  |
page canvas renderer <-- one completed frame batch
```

The compiler pipeline remains unchanged. Run requests use the serialized
dispatcher specified in §6. The runner instantiates once per Run and enters
the guest once per frame. No closure, record, Picture, or GC reference crosses
the FFI. The Medaka renderer traverses a Picture and issues scalar calls into
the worker's buffer. One structured-clone message carries the completed batch
to the page. There is no JSON serialization of Pictures and no message per
primitive. Start with ordinary JavaScript arrays; add packed buffers only if
profiling identifies transport as a bottleneck.

The page owns the visible canvas, browser scheduling, layout, and input listeners.
The worker owns guest execution, its host, and command construction. Medaka owns
the model, update logic, geometry, and drawing descriptions. Terminating a worker
releases its entire guest state and leaves canvas ownership on the page.

Proposed files below are named relative to their directory; they are not existing
files. Boundary signatures are contracts, not promised parser-valid declarations.

| Directory | Module/file | Responsibility and exports | Import boundary |
|---|---|---|---|
| `stdlib/` | `graphics.mdk` | Pure `Point`, `Color`, `Shape`, `Picture`; constructors described in §4. | Existing pure stdlib only; no host, animation, compiler, or DOM dependency. |
| `stdlib/` | `canvas_host.mdk` | Typed scalar externs, frame getters, `render : Picture -> <FFI "js/canvas"> Unit`. | `graphics` and needed stdlib; never `animation` or compiler modules. |
| `stdlib/` | `animation.mdk` | `Frame`, `Pointer`, abstract `Simulation model`, `drawing`, `animate`, `animateWith`, `simulation`, `runSimulation`. | `graphics`, `canvas_host`, existing stdlib only. |
| `playground/` | `animation_protocol.mjs` | Protocol version, limits, validators for frame inputs and batches. Exports `PROTOCOL_VERSION`, `LIMITS`, `validateFrameInput`, `validateFrameBatch`. | No DOM, worker globals, compiler, or host runtime. |
| `playground/` | `animation_host.mjs` | Per-session FFI binding factory: `createAnimationBindings() -> {bindings, beginInvocation(input), finishInvocation(), discard()}`. | Protocol only; no scheduling or DOM. |
| `playground/` | `animation_controller.mjs` | Page state machine: `createAnimationController(deps) -> {start, pause, resume, stop, resize, pointer, dispose}`. Inject worker factory, clock/rAF, renderer, and status sink. | Protocol; no editor/compiler imports and no WASM evaluation on the page. |
| `playground/` | `compile_dispatcher.mjs` | `createCompileDispatcher({createWorker}) -> {request, cancel, dispose}`; correlates and serializes Run compilations as specified in §6. | Worker messages only; no editor, canvas, or compiler implementation imports. |
| `playground/` | `canvas_renderer.mjs` | `createCanvasRenderer(canvas) -> {resize(viewport), present(batch), clear(), dispose()}`. | Protocol and Canvas 2D only. |

Extend `medaka_host.mjs` at its existing instantiation/entry seam to expose a
persistent program session (§6), keeping one implementation of import checks,
JSPI entry wrapping, flush discipline, and errors. Extend `worker.js` only to
route messages and guest output; `main.js` only wires the controller into the
editor/compile/UI flow. New subsystems belong in the modules above.

## 4. Medaka API and semantics

The pure graphics vocabulary is deliberately small:

```text
Point = { x : Float, y : Float }
Color = { red : Float, green : Float, blue : Float, alpha : Float }
Shape = Line Color Float Point Point
      | Circle Color Point Float
      | Polygon Color (List Point)
Picture = { background : Color, shapes : List Shape }

point   : Float -> Float -> Point
rgba    : Float -> Float -> Float -> Float -> Color
line    : Color -> Float -> Point -> Point -> Shape
circle  : Color -> Point -> Float -> Shape
polygon : Color -> List Point -> Shape
picture : Color -> List Shape -> Picture
```

The data constructors/fields needed by the renderer and pure tests are public.
Circle and Polygon are filled; Line's Float is stroke width. Shapes paint in list
order using source-over compositing. Each Picture replaces the entire frame,
including its background; trails must be represented in the model. Transparent
backgrounds clear previous pixels before painting.

Coordinates are logical CSS pixels, origin at the canvas center, x right and y
up. Stroke width and radius use those units. Frame width/height are the logical
viewport dimensions. The renderer owns the pixel-density transform. Zero-radius
circles and polygons with fewer than three points draw nothing. All numeric
values must be finite; colors must be in [0,1], widths positive, radii nonnegative,
and coordinates within the protocol's bound. Invalid data fails the whole frame
with a named graphics error, preserving the last completed image.
Stroke widths and radii are also bounded by the coordinate magnitude limit.

```text
Pointer = { x : Float, y : Float, inside : Bool, down : Bool }
Frame = { elapsed : Float, delta : Float, width : Float, height : Float,
          pointer : Pointer }

drawing      : Picture -> <FFI "js/canvas"> Unit
animate      : (Float -> Picture) -> <FFI "js/canvas"> Unit
animateWith  : (Frame -> Picture) -> <FFI "js/canvas"> Unit
simulation   : model -> (Frame -> model -> model)
               -> (Frame -> model -> Picture) -> Simulation model
runSimulation : Simulation model -> <FFI "js/canvas"> Unit
```

`animate` passes elapsed seconds. `animateWith` also exposes viewport and pointer
state. The callbacks above are pure Medaka functions; they never cross the ABI.
`drawing` requests a single frame. Each invocation permits exactly one drawing
entry operation; a second call is an error rather than an implicit extra frame.

`simulation` allocates a model cell inside the WASM instance, with no host call.
The user binds it once at module scope and calls `runSimulation` from `main`.
The first frame renders the initial model without updating it; subsequent frames
apply update exactly once, then view. A new Run creates a fresh instance and
initial model. Creating a simulation inside `main` recreates it each frame and
is documented as such. The spike must prove top-level construction and capture
work, without changing global evaluation semantics.

Conceptual usage (final syntax/examples must be compiled before publication):

```text
scene seconds = ...
main = animate scene

app = simulation initialModel update view
main = runSimulation app
```

These are two separate programs. Any other effect in an animation program's
`main` also repeats per frame. Host bindings may only be called during an entry
invocation, not during module initialization. A top-level pure scene or model is
fine; a top-level effectful drawing is a named initialization error.

Pure graphics work on every engine. Browser rendering has JS bindings only;
native build/run must retain the existing target/capability refusals. No fake
native drawing implementation or silently ignored effect is added. Availability
comes from the host's binding map, not from granting arbitrary JS execution.

## 5. Scalar ABI and frame protocol

Use signature-bearing `jsffi` imports and `<FFI "js/canvas">`, following
[the existing WASM FFI contract](../spec/WASM-SEMANTICS.md#31-the-jsffi-import-module-user-js-bindings).
The `medaka_canvas_v1_` JS-name prefix versions this application protocol. JS
binding names must be valid JavaScript identifiers, as required by the existing
scalar FFI. This prefix does not change the compiler ABI. The binding names are
the prefix followed by each suffix below, with the listed argument order:

| Suffix | Parameters -> result | Meaning |
|---|---|---|
| `begin` | Bool -> Unit | Begin one picture; True requests more frames. Must precede frame reads or drawing. |
| `elapsed`, `delta`, `width`, `height`, `pointerX`, `pointerY` | Unit -> Float | Read the immutable input snapshot for this invocation. |
| `pointerInside`, `pointerDown` | Unit -> Bool | Read pointer snapshot. |
| `background` | Float, Float, Float, Float -> Unit | RGBA; exactly once before shapes. |
| `line` | Float × 9 -> Unit | r,g,b,a,width,x1,y1,x2,y2. |
| `circle` | Float × 7 -> Unit | r,g,b,a,x,y,radius. |
| `polygonBegin` | Float × 4 -> Unit | RGBA; begin one polygon. |
| `polygonPoint` | Float, Float -> Unit | Append x,y to the current polygon. |
| `polygonEnd` | Unit -> Unit | Close the polygon, including a degenerate one. |
| `end` | Unit -> Unit | Seal one complete picture. |

Illegal ordering, unknown versions, nested polygons, missing background/end,
calls outside an invocation, and more than one picture fail explicitly. An
unclosed picture is an error even if `mdk_main` returns normally. `end` does not
publish anything: `finishInvocation` returns a batch only after successful guest
return. A trap after `end` discards the batch. These rules also apply when users
declare the externs directly.

No protocol call schedules work or posts a worker message. The worker sends at
most one frame batch after the entry returns. A console-only program produces
no batch. Opt-in is the executed `begin` call, never source scanning, imports,
stdout sentinels, or the chosen example name.

Page-to-worker envelopes:

```text
start {version, runId, wasm, isolated, input}
tick  {version, runId, frameId, input}

input = {elapsed, delta, viewport: {revision, width, height},
         pointer: {x, y, inside, down}}
```

Worker-to-page envelopes retain stdout/stderr/error/done and add:

```text
frame {version, runId, frameId, continuous, viewport, background, commands}
```

All output envelopes carry runId; frame/error replies identify the outstanding
frameId where applicable. Start computes frame 0 at elapsed=delta=0. `continuous`
must remain True after an animation starts; missing/reclassified frames are
protocol errors. A static picture is followed by done. Console-only programs
run once and send done as today. An animation sends frame acknowledgements,
never done after each frame. Stop terminates the worker from the page.
Identifiers and viewport revisions are nonnegative safe JS integers generated
by the page, never guest-provided values. Width/height must be positive and
finite. An absent pointer is `{x:0,y:0,inside:false,down:false}`. `viewport` in a
reply echoes the invocation's snapshot. For frame 0, measure the output container
and use a 16:9 viewport, falling back to 640 by 360 if it has no layout yet. This
lets console programs run before a canvas is visible. Later zero-size layout
changes suspend animation scheduling as specified in §7.

Commands are tagged plain values for Line, Circle, or Polygon with explicit
fields corresponding to the ABI. Only protocol data crosses messages; functions
and host objects cannot be requested. Validate both during worker construction
and before page replay. Proposed hard limits: 4,096 shapes, 16,384 total points,
coordinate magnitude 1,000,000, and 65,536 scalar FFI calls per invocation. The
protocol module owns these numbers; tests and documentation derive them. Limits
are enforced while accumulating, not after allocating an unbounded batch. These
limits bound this interface, not all memory a guest can allocate.

## 6. Persistent sessions, scheduling, and failure

Factor a shared session seam in `medaka_host.mjs`:

```text
createProgramSession(wasm, host, opts) -> Promise<ProgramSession>
ProgramSession.invokeMain() -> Promise<existing run outcome>
ProgramSession.dispose() -> void
```

Creation performs the existing old-entry and import-key checks and initialization.
`invokeMain` uses the existing promising/synchronous choice and flushes output on
every return or failure. Calls are serialized; overlapping entry is refused.
Any trap poisons the session; it cannot be reused. Dispose drops instance/host
references and prevents further entry. It is not preemption: worker termination
is the mechanism for stopping a running guest. `runProgram` becomes a one-call
wrapper over this seam, retaining its existing outcomes and `inProgram` meaning.
Initialization failures must keep their current diagnostic distinctions.

The animation path enforces the synchronous picture protocol; no async callback
or new JSPI requirement is introduced. Existing console programs, including
JSPI sleep, continue through the common session behavior. An animation entry
that suspends still owns the one outstanding frame and remains under its watchdog.

The controller has idle/loading, running, paused, stopped, and failed states.
Every Run advances a generation before loading/compiling. Async asset/compile
completions and all worker events check that generation before changing UI or
starting execution. A replacement cancels scheduling/listeners, invalidates the
old generation, and terminates its runner. A Stop during compilation also makes
the eventual result inert; compiler caching may remain alive.

Generation checks require correctly correlated compilation results. Replace the
current single-resolver `requestCompile` glue with a dispatcher that owns one
active transport request and at most one pending request, retaining only the
newest pending Run. `request({runId, source, assets})` returns a promise for
`{kind:"compiled", result}` (the existing compiler reply, including diagnostics)
or `{kind:"cancelled"}`. A worker failure rejects the promise. Replacing or
`cancel(runId)` settles that request as cancelled immediately. If already sent,
its transport slot stays occupied until its reply is consumed; cancellation must
not install a new resolver for that reply. Only then may the latest pending Run
be posted. A replaced pending request is settled, never left hanging.

Install stable message/error handlers per compiler worker. Each reply consumes
the dispatcher-owned active slot and can settle only its original request; the
run generation still gates UI effects. A worker error rejects all outstanding
non-cancelled requests, clears both slots, and drops the worker; the next Run
creates a new one. `dispose()` settles cancellations, terminates the compiler
worker, and ignores its late events by worker identity. This permits cache reuse
without overlapping compiler entry or changing `compiler-worker.js`'s wire format.
Test the actual dispatcher, not a controller mock that already returns correctly
correlated promises: A-start, Stop, B-start, A-reply, B-reply must execute only B,
settle both requests, and send B only after consuming A's reply.

Use page rAF timestamps as the single clock. At most one tick is outstanding.
Set the animation clock origin when frame 0 is first presented; asset loading,
compilation, and instantiation do not count as animation time.
The first-picture replay rule in §7 guarantees frame 0 remains presentable after
a resize. Do not dispatch frame 1 until that initial presentation occurs.
After a completed batch, present it on a browser animation opportunity and send
the next tick when ready. Do not queue missed ticks or run a catch-up loop. A
slow computation lowers frame rate without growing the queue. `elapsed` is active
time since start, excluding pauses; `delta` is time since the preceding dispatched
frame, clamped to 0.050 seconds. First and first-after-resume deltas are zero.
Pause/hidden time never advances either clock. Reset the sampling baseline on
resume. Applications requiring fixed-step physics can build an accumulator in
Medaka later; v1 performs one update per delivered frame.

The existing 10-second startup/console deadline remains. After successful
animation opt-in, replace the total-session deadline with a 2-second deadline
for each outstanding frame, armed on dispatch and cleared only on completion.
There is no deadline while idle or paused. Opt-in alone cannot clear the startup
deadline: the first entry must return successfully. Pause while a frame is in
flight does not cancel its watchdog; hold its completed batch for resume, except
that the initial picture may present while paused as specified in §7. Stop
remains available throughout. Tests inject shorter deadlines instead of waiting.

On errors, discard partial drawing, retain the last completed canvas, flush
stdout/stderr, show the existing runtime diagnostic once, terminate the session,
and allow a fresh Run. No attempt is made to recover half-mutated Medaka state.

## 7. Canvas, interaction, examples, and packaging

Reveal the canvas when the first valid picture arrives, while keeping text
output available. Provide accessible Pause/Resume and Stop buttons. Run replaces
an active animation with the current source. A static picture remains visible
after done. Reduced-motion preference starts a continuous example paused after
its first frame; the visitor can explicitly resume. Page visibility suspension
is distinct from manual pause, so returning to a tab does not undo manual pause.

Use ResizeObserver and a fresh layout measurement before dispatch. Device pixel
ratio is capped at 2 and backing dimensions at 2,048 per axis; reduce effective
pixel scale to fit while preserving logical coordinates. Zero-sized canvases
pause frame scheduling. Rendering resets the transform and state each frame,
clears backing pixels, then establishes centered, y-up logical coordinates. A
resize increments a viewport revision. Once a continuous animation has presented
frame 0, old-revision batches are acknowledged but not presented; the next input
uses the new revision.

The initial picture has precedence over that stale-revision rule: retain its
validated batch and replay its logical geometry in the current viewport, even
if its input revision is old. The first image may use geometry computed for the
original dimensions; the next tick uses the new dimensions. This preserves the
initial Simulation model, without an extra update or another guest invocation.
If layout is zero-sized or the page hidden, retain only this one initial batch
until presentation becomes possible. Manual pause or reduced-motion pause permits
this initial still image but no subsequent tick. Initialize the clock on actual
presentation; if paused, active time remains zero until resume. Stop/replacement
discards the retained batch. Static pictures use the same initial rule, retain
their batch after done, and replay it on later resize without guest re-entry.

Deterministic tests cover resize before frame 0 returns in both static and
continuous modes, zero-size then visible layout, and Pause/Resume before first
presentation. In every case the initial model is presented before any simulation
update, replay never invokes the guest again, elapsed/delta begin at zero, and
stale later continuous frames remain suppressed.

Support one primary pointer via pointer events, including touch. Map coordinates
through the measured canvas rectangle to logical coordinates. Capture the pointer
while down; release/cancel, blur, and hiding clear `down`. Pointer movement is
coalesced into the next frame snapshot. No event listeners accumulate across Runs.

Examples are complete, standalone editable source strings, shared through the
existing source permalink mechanism. Store animation examples once in an
`animation_examples.mjs` module under `playground/`, exporting an id-to-source
record consumed by both UI and tests. Do not bake scene logic into JavaScript.

- Cube: eight vertices, twelve edges, rotation and perspective in Medaka. Put
  the whole cube beyond the near plane by construction; test known projections.
  Pointer position can control rotation offset. Filled faces are optional polish.
- Lissajous: a deterministic time-to-picture example demonstrating lists and trig.
- Bouncing balls: a deterministic initial model and explicit pure update/view;
  bounded delta, wall collision, and primary-pointer interaction.

Reuse existing numeric/list helpers after consulting the stdlib index. Keep
cube-specific Vec3/projection helpers in the example until another consumer
justifies a public 3D library. Imported graphics modules must reach both compile
and editor analyze/hover/completion through the existing extra-module VFS.

Update the explicit site asset list and COEP headers for every new transitive
worker import. The stdlib source manifest, generated reference, development
server, and built site must contain the same library/example surface. Test the
built site as well as the development tree. Production deployment is a later
release action using the existing playground procedure, not part of this plan.

## 8. Verification and language-extension decision

The spike must compile real source through `compile.mjs` plus the shipped WAT
assembler, instantiate once, and enter three times with distinct input snapshots.
It must prove changed drawing output, persistent model state, a fresh-instance
reset, and a normal console program that executes once. Repeat with JSPI disabled.
Native CLI compilation alone cannot discharge this question.

Pure Medaka tests assert geometry/model outputs using `expectEqual` and
`expectWithin`. JavaScript tests inject time, worker messages, and a recording
canvas. Integration tests compile actual examples and compare frame commands at
fixed times. Browser tests prove the visible canvas changes, controls work,
runaways stop, and reruns do not revive old workers. Exact cross-engine pixel
goldens are unsuitable because antialiasing differs; combine command assertions
with tolerant pixel/nonempty/change checks.

The implementation plan names CI ownership and concrete acceptance groups.
Performance reports separate guest calculation, FFI command construction,
transport, page replay, and compilation. Aim for 60 fps for the cube on a named
desktop/browser, but do not make a noisy frame-time threshold a required gate.

If the spike fails, preserve the smallest reproducer and distinguish a compiler
bug from an unsupported contract. Do not restart the instance each frame,
recompile every frame, introduce a blocking sleep loop, or move guest code onto
the page. Amend the plan around typed scalar foreign exports if necessary;
general callbacks require a separate lifecycle design. Neither is silently
included in a downstream slice.
