export const PROTOCOL_VERSION = 1;
export const LIMITS = Object.freeze({
  maxShapes: 4096,
  maxPoints: 16384,
  maxCoordinate: 1_000_000,
  maxCalls: 65536,
});

function fail(message) {
  const error = new Error(`E-GRAPHICS-PROTOCOL: ${message}`);
  error.name = 'GraphicsError';
  throw error;
}

function record(value, fields, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || ![Object.prototype, null].includes(Object.getPrototypeOf(value)))
    fail(`${label} must be a plain object`);
  for (const key of Object.keys(value))
    if (!fields.includes(key)) fail(`${label} has unknown field ${key}`);
}

function number(value, lo, hi, label) {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < lo || value > hi)
    fail(`${label} must be finite and in [${lo}, ${hi}]`);
}

function integer(value, label) {
  if (!Number.isSafeInteger(value) || value < 0) fail(`${label} must be a nonnegative safe integer`);
}

function boolean(value, label) {
  if (typeof value !== 'boolean') fail(`${label} must be a boolean`);
}

function point(value, label) {
  record(value, ['x', 'y'], label);
  number(value.x, -LIMITS.maxCoordinate, LIMITS.maxCoordinate, `${label}.x`);
  number(value.y, -LIMITS.maxCoordinate, LIMITS.maxCoordinate, `${label}.y`);
}

function color(value, label) {
  record(value, ['red', 'green', 'blue', 'alpha'], label);
  for (const field of ['red', 'green', 'blue', 'alpha']) number(value[field], 0, 1, `${label}.${field}`);
}

function viewport(value) {
  record(value, ['revision', 'width', 'height'], 'viewport');
  integer(value.revision, 'viewport.revision');
  for (const field of ['width', 'height']) {
    number(value[field], 0, Number.MAX_VALUE, `viewport.${field}`);
    if (value[field] === 0) fail(`viewport.${field} must be positive`);
  }
}

// The returned snapshot cannot be changed by a caller mutating its input object.
export function validateFrameInput(input) {
  record(input, ['elapsed', 'delta', 'viewport', 'pointer'], 'input');
  number(input.elapsed, 0, Number.MAX_VALUE, 'elapsed');
  number(input.delta, 0, 0.050, 'delta');
  viewport(input.viewport);
  const pointer = input.pointer === undefined ? { x: 0, y: 0, inside: false, down: false } : input.pointer;
  record(pointer, ['x', 'y', 'inside', 'down'], 'pointer');
  point({ x: pointer.x, y: pointer.y }, 'pointer');
  boolean(pointer.inside, 'pointer.inside');
  boolean(pointer.down, 'pointer.down');
  return {
    elapsed: input.elapsed, delta: input.delta,
    viewport: { ...input.viewport }, pointer: { ...pointer },
  };
}

export function validateFrameBatch(batch) {
  record(batch, ['type', 'version', 'runId', 'frameId', 'continuous', 'viewport', 'background', 'commands'], 'batch');
  if (batch.version !== PROTOCOL_VERSION) fail(`unsupported version ${batch.version}`);
  if (batch.type !== undefined && batch.type !== 'frame') fail('batch.type must be frame');
  for (const field of ['runId', 'frameId'])
    if (batch[field] !== undefined) integer(batch[field], field);
  boolean(batch.continuous, 'continuous');
  viewport(batch.viewport);
  color(batch.background, 'background');
  if (!Array.isArray(batch.commands) || batch.commands.length > LIMITS.maxShapes)
    fail(`commands must be an array of at most ${LIMITS.maxShapes} shapes`);
  let points = 0;
  for (const command of batch.commands) {
    if (!command || typeof command !== 'object') fail('command must be a plain object');
    switch (command.type) {
      case 'line':
        record(command, ['type', 'color', 'width', 'from', 'to'], 'line');
        color(command.color, 'line.color');
        number(command.width, 0, LIMITS.maxCoordinate, 'line.width');
        if (command.width === 0) fail('line.width must be positive');
        point(command.from, 'line.from');
        point(command.to, 'line.to');
        points += 2;
        break;
      case 'circle':
        record(command, ['type', 'color', 'center', 'radius'], 'circle');
        color(command.color, 'circle.color');
        point(command.center, 'circle.center');
        number(command.radius, 0, LIMITS.maxCoordinate, 'circle.radius');
        points++;
        break;
      case 'polygon':
        record(command, ['type', 'color', 'points'], 'polygon');
        color(command.color, 'polygon.color');
        if (!Array.isArray(command.points) || command.points.length > LIMITS.maxPoints - points)
          fail(`total points exceed ${LIMITS.maxPoints}`);
        for (const p of command.points) point(p, 'polygon.point');
        points += command.points.length;
        break;
      default: fail(`unknown command ${command.type}`);
    }
    if (points > LIMITS.maxPoints) fail(`total points exceed ${LIMITS.maxPoints}`);
  }
  return batch;
}
