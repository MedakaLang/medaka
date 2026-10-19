import { validateFrameBatch } from './animation_protocol.mjs';

export function createCanvasRenderer(canvas) {
  const ctx = canvas.getContext('2d');
  let viewport = null;
  let scale = 1;
  const paint = ({ red, green, blue, alpha }) => `rgba(${red * 255},${green * 255},${blue * 255},${alpha})`;
  function clear() {
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
  }
  return {
    resize(next) {
      viewport = { ...next };
      scale = Math.min(next.dpr || 1, 2, 2048 / next.width, 2048 / next.height);
      canvas.width = Math.max(1, Math.round(next.width * scale));
      canvas.height = Math.max(1, Math.round(next.height * scale));
    },
    present(batch) {
      validateFrameBatch(batch);
      if (!viewport) return;
      clear();
      ctx.globalAlpha = 1;
      ctx.globalCompositeOperation = 'source-over';
      ctx.lineCap = 'butt';
      ctx.lineJoin = 'miter';
      ctx.setLineDash([]);
      ctx.fillStyle = paint(batch.background);
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      ctx.setTransform(scale, 0, 0, -scale, canvas.width / 2, canvas.height / 2);
      for (const command of batch.commands) {
        ctx.beginPath();
        if (command.type === 'line') {
          ctx.strokeStyle = paint(command.color);
          ctx.lineWidth = command.width;
          ctx.moveTo(command.from.x, command.from.y);
          ctx.lineTo(command.to.x, command.to.y);
          ctx.stroke();
        } else {
          ctx.fillStyle = paint(command.color);
          if (command.type === 'circle') {
            if (command.radius === 0) continue;
            ctx.arc(command.center.x, command.center.y, command.radius, 0, 2 * Math.PI);
          } else {
            if (command.points.length < 3) continue;
            ctx.moveTo(command.points[0].x, command.points[0].y);
            for (const point of command.points.slice(1)) ctx.lineTo(point.x, point.y);
            ctx.closePath();
          }
          ctx.fill();
        }
      }
    },
    clear,
    dispose() { clear(); viewport = null; },
  };
}
