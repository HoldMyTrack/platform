import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cameraFromHash, panOffset, wheelDelta } from '../scripts/landing-shots/camera.mjs';

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