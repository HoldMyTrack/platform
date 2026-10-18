import { test } from 'node:test';
import assert from 'node:assert/strict';
import { GLOBE_MAX_ZOOM, globeMinZoom, globeProjection } from '../src/map/globe.ts';

test('the web map is a globe out to GLOBE_MAX_ZOOM and flat one zoom further in', () => {
  assert.equal(GLOBE_MAX_ZOOM, 3);
  assert.deepEqual(globeProjection().type, ['interpolate', ['linear'], ['zoom'], 3, 'vertical-perspective', 4, 'mercator']);
});

test('zoomed all the way out the globe spans 80% of the shorter side', () => {
  // The disc MapLibre's camera sees from d above the globe's near point; 1.5 heights at its default fov.
  const disc = (zoom, height, d) => {
    const radius = (512 * 2 ** zoom) / (2 * Math.PI);
    return (2 * d * radius) / Math.sqrt(d * d + 2 * d * radius);
  };
  for (const [width, height] of [[1220, 843], [390, 575], [800, 800]]) {
    assert.ok(Math.abs(disc(globeMinZoom(width, height, 36.87), height, 1.5 * height) - 0.8 * Math.min(width, height)) < 1e-3);
  }
  // A wider fov brings the camera closer: tan(30°) puts it 0.5 / tan(30°) heights away.
  const d = 0.5 / Math.tan(Math.PI / 6) * 843;
  assert.ok(Math.abs(disc(globeMinZoom(1220, 843, 60), 843, d) - 0.8 * 843) < 1e-6);
});

test('the floor never passes GLOBE_MAX_ZOOM, so a huge screen still reaches the globe', () => {
  assert.equal(globeMinZoom(8000, 6000, 36.87), GLOBE_MAX_ZOOM);
});

test('a container not laid out yet gets zoom 0', () => {
  assert.equal(globeMinZoom(0, 0, 36.87), 0);
  assert.equal(globeMinZoom(1200, 0, 36.87), 0);
});
