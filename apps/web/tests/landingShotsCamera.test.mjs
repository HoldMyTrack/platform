import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MIN_DRAG, cameraFromHash, dragSplit, panOffset, wheelDelta } from '../scripts/landing-shots/camera.mjs';

test('cameraFromHash reads zoom, lat and lon, theme or not', () => {
  assert.deepEqual(cameraFromHash('#map=10.98/41.44751/-81.64018'), { zoom: 10.98, lat: 41.44751, lon: -81.64018 });
  assert.deepEqual(cameraFromHash('#map=3.00/-12.5/170.1&theme=dark'), { zoom: 3, lat: -12.5, lon: 170.1 });
  assert.equal(cameraFromHash(''), null);
});

test('wheelDelta zooms in for a positive change and out for a negative one, by the same amount', () => {
  const zoomIn = wheelDelta(0.5);
  assert.ok(zoomIn < 0);
  assert.equal(wheelDelta(-0.5), -zoomIn);
  // scale 2^0.5 = 2 / (1 + e^(-|d|/450))
  assert.ok(Math.abs(2 / (1 + Math.exp(zoomIn / 450)) - Math.SQRT2) < 1e-9);
});

test('panOffset is zero at the target, and east and south are positive', () => {
  const here = { zoom: 11, lat: 41.4, lon: -81.6 };
  assert.deepEqual(panOffset(here, here), { x: 0, y: 0 });
  const east = panOffset(here, { lat: 41.4, lon: -81.5 });
  assert.ok(Math.abs(east.x - (0.1 * 512 * 2 ** 11) / 360) < 1e-9);
  assert.equal(east.y, 0);
  assert.ok(panOffset(here, { lat: 41.3, lon: -81.6 }).y > 0);
});

test('panOffset doubles with each zoom level', () => {
  const target = { lat: 41.5, lon: -81.7 };
  const a = panOffset({ zoom: 10, lat: 41.4, lon: -81.6 }, target);
  const b = panOffset({ zoom: 11, lat: 41.4, lon: -81.6 }, target);
  assert.ok(Math.abs(b.x - 2 * a.x) < 1e-9 && Math.abs(b.y - 2 * a.y) < 1e-9);
});

test('dragSplit makes two drags that sum to the offset, neither short enough to be a click', () => {
  for (const [x, y] of [[0, 0], [80, 80], [79.6, 80.3], [-80, 80], [500, -20], [0.4, -0.3], [-1200, 900]]) {
    const drags = dragSplit(x, y);
    assert.equal(drags.length, 2);
    const [sx, sy] = drags.reduce(([ax, ay], [dx, dy]) => [ax + dx, ay + dy], [0, 0]);
    assert.ok(Math.abs(sx + x) < 1e-9 && Math.abs(sy + y) < 1e-9, `sums to (${-x}, ${-y})`);
    for (const [dx, dy] of drags) assert.ok(Math.hypot(dx, dy) >= MIN_DRAG, `(${x}, ${y}): a drag of ${Math.hypot(dx, dy)} px`);
  }
});

test("dragSplit keeps a long pan's first drag no longer than it needs", () => {
  const [[fx, fy]] = dragSplit(0, -400);
  assert.ok(Math.hypot(fx, fy) < 400, `first drag ${Math.hypot(fx, fy)} px for a 400 px pan`);
});
