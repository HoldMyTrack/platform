import { test } from 'node:test';
import assert from 'node:assert/strict';
import { invertedChecks, mapHiddenIds, targetSummaryKind, toggled, toolbarTarget, withoutIds } from '../src/map/selection.ts';

const track = (id, activityType = 'walking', distanceMeters = 1000, pending = false) => ({ id, activityType, distanceMeters, pending });

test('toggled adds a missing item and removes a present one', () => {
  assert.deepEqual([...toggled(new Set(['a']), 'b')], ['a', 'b']);
  assert.deepEqual([...toggled(new Set(['a', 'b']), 'a')], ['b']);
});

test('the toolbar target is the checked set itself, so state identity holds', () => {
  const checked = new Set(['a']);
  assert.equal(toolbarTarget(checked, 'b'), checked);
});

test('withoutIds returns the same set when none of the ids are in it', () => {
  const set = new Set(['a', 'b']);
  assert.equal(withoutIds(set, new Set(['x'])), set);
  assert.deepEqual([...withoutIds(set, new Set(['a', 'x']))], ['b']);
});

test('inverting checks only the listed rows', () => {
  const listed = [track('a'), track('b'), track('c')];
  // "z" is checked but filtered out of the list: dropped.
  assert.deepEqual([...invertedChecks(listed, new Set(['a', 'z']))].sort(), ['b', 'c']);
});

test('the map hides filtered-out, hidden and pending tracks', () => {
  const tracks = [track('walk'), track('run', 'running'), track('ride', 'cycling'), track('busy', 'walking', 1000, true)];
  const hidden = mapHiddenIds(tracks, new Set(['running']), null, new Set(['ride']), ['busy']);
  assert.deepEqual([...hidden].sort(), ['busy', 'ride', 'run']);
});

test("the footer names a focused row as focused, never as checked", () => {
  assert.equal(targetSummaryKind(0, 1), 'focused');
  assert.equal(targetSummaryKind(2, 2), 'checked');
  // Nothing to act on reads as nothing checked.
  assert.equal(targetSummaryKind(0, 0), 'checked');
});
