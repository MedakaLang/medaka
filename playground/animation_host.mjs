import { PROTOCOL_VERSION, LIMITS, validateFrameInput, validateFrameBatch } from './animation_protocol.mjs';

export function createAnimationBindings() {
  let invocation = null;

  function fail(message, initialization = false) {
    const error = new Error(`${initialization ? 'E-GRAPHICS-INITIALIZATION' : 'E-GRAPHICS-PROTOCOL'}: ${message}`);
    error.name = 'GraphicsError';
    if (invocation) invocation.error = error;
    throw error;
  }

  function call() {
    if (!invocation) fail('canvas binding called outside an entry invocation', true);
    if (invocation.error) throw invocation.error;
    if (++invocation.calls > LIMITS.maxCalls) fail(`scalar calls exceed ${LIMITS.maxCalls}`);
    return invocation;
  }

  function phase(expected) {
    const current = call();
    if (current.phase !== expected) fail(`expected ${expected}, received a call during ${current.phase}`);
    return current;
  }

  function finite(value, lo, hi, label) {
    if (typeof value !== 'number' || !Number.isFinite(value) || value < lo || value > hi)
      fail(`${label} must be finite and in [${lo}, ${hi}]`);
    return value;
  }

  const coordinate = (value) => finite(value, -LIMITS.maxCoordinate, LIMITS.maxCoordinate, 'coordinate');
  const point = (x, y) => ({ x: coordinate(x), y: coordinate(y) });
  const color = (red, green, blue, alpha) => {
    for (const value of [red, green, blue, alpha]) finite(value, 0, 1, 'color');
    return { red, green, blue, alpha };
  };

  function reserve(current, points, shape = true) {
    if (shape && current.commands.length >= LIMITS.maxShapes) fail(`shapes exceed ${LIMITS.maxShapes}`);
    if (current.points + points > LIMITS.maxPoints) fail(`total points exceed ${LIMITS.maxPoints}`);
    current.points += points;
  }

  const methods = {
    begin(continuous) {
      const current = phase('ready');
      if (typeof continuous !== 'boolean') fail('continuous must be a boolean');
      current.continuous = continuous;
      current.phase = 'background';
    },
    background(red, green, blue, alpha) {
      const current = phase('background');
      current.background = color(red, green, blue, alpha);
      current.phase = 'shapes';
    },
    line(red, green, blue, alpha, width, x1, y1, x2, y2) {
      const current = phase('shapes');
      reserve(current, 2);
      finite(width, 0, LIMITS.maxCoordinate, 'stroke width');
      if (width === 0) fail('stroke width must be positive');
      current.commands.push({ type: 'line', color: color(red, green, blue, alpha), width,
        from: point(x1, y1), to: point(x2, y2) });
    },
    circle(red, green, blue, alpha, x, y, radius) {
      const current = phase('shapes');
      reserve(current, 1);
      finite(radius, 0, LIMITS.maxCoordinate, 'radius');
      current.commands.push({ type: 'circle', color: color(red, green, blue, alpha), center: point(x, y), radius });
    },
    polygonBegin(red, green, blue, alpha) {
      const current = phase('shapes');
      reserve(current, 0);
      current.polygon = { type: 'polygon', color: color(red, green, blue, alpha), points: [] };
      current.phase = 'polygon';
    },
    polygonPoint(x, y) {
      const current = phase('polygon');
      reserve(current, 1, false);
      current.polygon.points.push(point(x, y));
    },
    polygonEnd() {
      const current = phase('polygon');
      current.commands.push(current.polygon);
      current.polygon = null;
      current.phase = 'shapes';
    },
    end() { phase('shapes').phase = 'sealed'; },
  };
  for (const field of ['elapsed', 'delta', 'width', 'height', 'pointerX', 'pointerY', 'pointerInside', 'pointerDown']) {
    methods[field] = () => {
      const current = call();
      if (current.phase === 'ready' || current.phase === 'sealed') fail('frame reads require an open picture');
      const { input } = current;
      if (field === 'width' || field === 'height') return input.viewport[field];
      if (field.startsWith('pointer')) {
        const suffix = field.slice('pointer'.length);
        return input.pointer[suffix[0].toLowerCase() + suffix.slice(1)];
      }
      return input[field];
    };
  }
  const bindings = Object.fromEntries(Object.entries(methods).map(([name, fn]) => [`medaka_canvas_v1_${name}`, fn]));

  return {
    bindings,
    beginInvocation(input) {
      if (invocation) fail('an entry invocation is already active');
      const snapshot = validateFrameInput(input);
      invocation = { input: snapshot, phase: 'ready', commands: [], polygon: null, points: 0, calls: 0, error: null };
    },
    finishInvocation() {
      if (!invocation) fail('no entry invocation is active');
      try {
        if (invocation.error) throw invocation.error;
        if (invocation.phase === 'ready') return null;
        if (invocation.phase !== 'sealed') fail(`incomplete picture during ${invocation.phase}`);
        return validateFrameBatch({ version: PROTOCOL_VERSION, continuous: invocation.continuous,
          viewport: invocation.input.viewport, background: invocation.background, commands: invocation.commands });
      } finally {
        invocation = null;
      }
    },
    // A guest trap, including one after end, must discard the uncommitted batch.
    discard() { invocation = null; },
  };
}
