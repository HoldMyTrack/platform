import { test } from 'node:test';
import assert from 'node:assert/strict';
import { latestRows, missingRows, selectionKept, windowActivities } from '../src/map/editWindowRows.ts';

const row = (id, name) => ({ id, name });

test('the window keeps the newest row each list showed, and only its own', () => {
  const first = latestRows(new Map(), [row('a', 'Old'), row('x', 'Other')], ['a']);
  assert.deepEqual([...first.keys()], ['a']);
  const renamed = latestRows(first, [row('a', 'New')], ['a']);
  assert.equal(renamed.get('a').name, 'New');
  // A list without the row keeps the last one seen, not the detail read at opening.
  const gone = latestRows(renamed, [row('x', 'Other')], ['a']);
  assert.equal(gone, renamed);
  assert.equal(windowActivities([{ id: 'a', name: 'Opening', description: 'd' }], gone)[0].name, 'New');
});

test('an activity with no row seen keeps its detail', () => {
  assert.deepEqual(windowActivities([{ id: 'a', name: 'Opening' }], new Map()), [{ id: 'a', name: 'Opening' }]);
});

test('the rows a list lacks are read again', () => {
  assert.deepEqual(missingRows(['a', 'b'], [row('b')]), ['a']);
  assert.deepEqual(missingRows(['a'], [row('a')]), []);
});

test("the selection keeps the open window's activities", () => {
  assert.deepEqual(selectionKept(['x'], null), ['x']);
  assert.deepEqual(selectionKept(['x', 'a'], ['a', 'b']).sort(), ['a', 'b', 'x']);
});
