// Covers docs/SPEC.md FR-4.6: the font the direction chevrons are drawn in.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { CHEVRON_FONT, CHEVRON_RANGE, chevronBitmap, chevronFontBytes, chevronOutline } from '../scripts/chevronFont.mjs';

test('the served font is what the generator writes', async () => {
  const served = await readFile(new URL(`../public/basemap/fonts/${CHEVRON_FONT}/${CHEVRON_RANGE}.pbf`, import.meta.url));
  assert.deepEqual(new Uint8Array(served), chevronFontBytes());
});

test('the chevron points along +x and spans the whole height', () => {
  const outline = chevronOutline();
  const tip = outline.reduce((a, b) => (b[0] > a[0] ? b : a));
  assert.equal(tip[1], 12);
  assert.deepEqual([Math.min(...outline.map(([, y]) => y)), Math.max(...outline.map(([, y]) => y))], [0, 24]);
});

test('the distance field is inside the arm, outside the notch', () => {
  const { bitmap, width } = chevronBitmap();
  const at = (x, y) => bitmap[(y + 3) * (width + 6) + x + 3];
  assert.ok(at(18, 12) > 191, 'on the tip');
  assert.ok(at(2, 12) < 191, 'in the notch behind it');
});
