import { test } from 'node:test';
import assert from 'node:assert/strict';
import { infoReadDelay, infoShowsBands, invertedChecks, mapHiddenIds, targetSummaryKind, toggled, toolbarTarget, withoutIds } from '../src/map/selection.ts';

const track = (id, trackType = 'walking', distanceMeters = 1000, pending = false) => ({ id, trackType, distanceMeters, pending });

test('toggled adds a missing item and removes a present one', () => {
  assert.deepEqual([...toggled(new Set(['a']), 'b')], ['a', 'b']);
  assert.deepEqual([...toggled(new Set(['a', 'b']), 'a')], ['b']);
});

test('the toolbar target is the checked set itself, so state identity holds', () => {
  const checked = new Set(['a']);
  assert.equal(toolbarTarget(checked, 'b'), checked);
});

test('Info shows the bands legend while the target is the focused track alone', () => {
  assert.equal(infoShowsBands(toolbarTarget(new Set(), 'a'), 'a', true), true);
  assert.equal(infoShowsBands(toolbarTarget(new Set(['a']), 'a'), 'a', true), true);
  assert.equal(infoShowsBands(toolbarTarget(new Set(['a', 'b']), 'a'), 'a', true), false);
  assert.equal(infoShowsBands(toolbarTarget(new Set(['b']), 'a'), 'a', true), false);
  assert.equal(infoShowsBands(toolbarTarget(new Set(), 'a'), 'a', false), false);
});

test('Info reads at once the first time, then waits for a changed target to settle', () => {
  assert.equal(infoReadDelay(null), 0);
  assert.equal(infoReadDelay('a'), 400);
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
