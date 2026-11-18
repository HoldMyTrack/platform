import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rowsStandFor } from '../src/ui/listRows.ts';

const area = (west) => JSON.stringify({ area: { bbox: [west, 0, west + 1, 1] } });
const story = (id) => JSON.stringify({ story: { story: id } });

test('the rows read for the query stand for it', () => {
  assert.equal(rowsStandFor(story('s1'), story('s1')), true);
  assert.equal(rowsStandFor(area(0), area(0)), true);
});

test("a move of the map keeps the last area's rows until the new ones land", () => {
  assert.equal(rowsStandFor(area(1), area(0)), true);
});

test("a Story opened, switched or closed shows none of the last list's rows", () => {
  assert.equal(rowsStandFor(story('s1'), area(0)), false);
  assert.equal(rowsStandFor(story('s2'), story('s1')), false);
  assert.equal(rowsStandFor(area(0), story('s1')), false);
});

test('nothing read yet stands for nothing', () => {
  assert.equal(rowsStandFor(area(0), null), false);
});
