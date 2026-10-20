export const ANIMATION_EXAMPLES = {
  cube: `-- Eight vertices and twelve edges, rotated before perspective projection.
import animation.{animateWith, Frame}
import graphics.{Picture, Point, picture, rgba, line, point}

data Vec3 = Vec3 Float Float Float

project : Float -> Float -> Float -> Vec3 -> Point
project angle tilt size (Vec3 x y z) =
  let rx = x * cos angle + z * sin angle
  let rz = z * cos angle - x * sin angle
  let ry = y * cos tilt - rz * sin tilt
  let depth = y * sin tilt + rz * cos tilt
  let sx = rx * cos 0.12 - ry * sin 0.12
  let sy = rx * sin 0.12 + ry * cos 0.12
  let scale = size * 8.0 / (8.0 + depth)
  point (sx * scale) (sy * scale)

scene : Frame -> Picture
scene frame =
  let offset = if frame.pointer.inside then frame.pointer.x * 0.01 else 0.0
  let angle = 0.7 + frame.elapsed * 0.7 + offset
  let tilt = 0.55 + frame.elapsed * 0.25
  let size = min frame.width frame.height * 0.2
  let a = project angle tilt size (Vec3 -1.0 -1.0 -1.0)
  let b = project angle tilt size (Vec3 1.0 -1.0 -1.0)
  let c = project angle tilt size (Vec3 1.0 1.0 -1.0)
  let d = project angle tilt size (Vec3 -1.0 1.0 -1.0)
  let e = project angle tilt size (Vec3 -1.0 -1.0 1.0)
  let f = project angle tilt size (Vec3 1.0 -1.0 1.0)
  let g = project angle tilt size (Vec3 1.0 1.0 1.0)
  let h = project angle tilt size (Vec3 -1.0 1.0 1.0)
  let ink = rgba 0.3 0.85 1.0 1.0
  picture (rgba 0.025 0.035 0.07 1.0) [
    line ink 2.0 a b,
    line ink 2.0 b c,
    line ink 2.0 c d,
    line ink 2.0 d a,
    line ink 2.0 e f,
    line ink 2.0 f g,
    line ink 2.0 g h,
    line ink 2.0 h e,
    line ink 2.0 a e,
    line ink 2.0 b f,
    line ink 2.0 c g,
    line ink 2.0 d h,
  ]

main = animateWith scene
`,
  lissajous: `-- A closed curve sampled at 96 evenly spaced parameter values.
import animation.{animateWith, Frame}
import graphics.{Picture, Point, Shape, picture, rgba, line, circle, point}

sampleCount : Int
sampleCount = 96

angleStep : Float
angleStep = 2.0 * pi / intToFloat sampleCount

sample : Frame -> Float -> Point
sample frame u =
  point
    (frame.width * 0.38 * sin (3.0 * u + frame.elapsed))
    (frame.height * 0.38 * sin (2.0 * u))

segment : Frame -> Int -> Shape
segment frame index =
  let u = intToFloat index * angleStep
  let v = intToFloat (index + 1) * angleStep
  line (rgba 0.95 0.45 0.7 1.0) 2.0 (sample frame u) (sample frame v)

scene : Frame -> Picture
scene frame =
  let lastIndex = sampleCount - 1
  picture
    (rgba 0.04 0.025 0.06 1.0)
    (map (segment frame) [0..=lastIndex]
      ++ [circle (rgba 1.0 0.9 0.6 1.0) (sample frame frame.elapsed) 5.0])

main = animateWith scene
`,
  balls: `-- Deterministic wall bounces. Hold the primary pointer to pull the balls.
import animation.{Frame, Simulation, simulation, runSimulation}
import graphics.{Picture, Color, Shape, picture, rgba, circle, point}

data Ball = Ball {
  x : Float,
  y : Float,
  vx : Float,
  vy : Float,
  radius : Float,
  color : Color,
}

initial : List Ball
initial = [
  Ball {
    x = -90.0,
    y = 45.0,
    vx = 110.0,
    vy = 75.0,
    radius = 14.0,
    color = rgba 0.3 0.85 1.0 1.0,
  },
  Ball {
    x = 65.0,
    y = -30.0,
    vx = -85.0,
    vy = 120.0,
    radius = 20.0,
    color = rgba 1.0 0.55 0.3 1.0,
  },
  Ball {
    x = 0.0,
    y = 0.0,
    vx = 65.0,
    vy = -95.0,
    radius = 11.0,
    color = rgba 0.65 1.0 0.45 1.0,
  },
]

stepBall : Frame -> Ball -> Ball
stepBall frame ball =
  let dt = frame.delta
  let pulling = frame.pointer.inside && frame.pointer.down
  let ax = if pulling then (frame.pointer.x - ball.x) * 2.0 else 0.0
  let ay = if pulling then (frame.pointer.y - ball.y) * 2.0 else 0.0
  let vx = ball.vx + ax * dt
  let vy = ball.vy + ay * dt
  let x = ball.x + vx * dt
  let y = ball.y + vy * dt
  let limitX = max 0.0 (frame.width / 2.0 - ball.radius)
  let limitY = max 0.0 (frame.height / 2.0 - ball.radius)
  let nextX = max (0.0 - limitX) (min limitX x)
  let nextY = max (0.0 - limitY) (min limitY y)
  let nextVx =
    if x > limitX then 0.0 - abs vx else if x < 0.0 - limitX then abs vx else vx
  let nextVy =
    if y > limitY then 0.0 - abs vy else if y < 0.0 - limitY then abs vy else vy
  { ball | x = nextX, y = nextY, vx = nextVx, vy = nextVy }

update : Frame -> List Ball -> List Ball
update frame balls = map (stepBall frame) balls

drawBall : Ball -> Shape
drawBall ball = circle ball.color (point ball.x ball.y) ball.radius

view : Frame -> List Ball -> Picture
view _ balls = picture (rgba 0.025 0.05 0.045 1.0) (map drawBall balls)

-- Keep this binding outside main so the model survives the next frame.
app : Simulation (List Ball)
app = simulation initial update view
main = runSimulation app
`,
};
