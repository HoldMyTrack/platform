import { test } from 'node:test';
import assert from 'node:assert/strict';
import { emptySelection, initialSession, mapSessionReducer } from '../src/map/session.ts';

const reduce = (state, ...events) => events.reduce(mapSessionReducer, state);
const withSelection = (selection) => ({ ...initialSession(null), selection: { ...emptySelection(), ...selection } });

test('leaving Normal sets the checked group and focus aside, and Normal brings them back', () => {
  const start = withSelection({ checked: new Set(['a']), focused: 'b', hidden: new Set(['c']) });
  const fog = reduce(start, { type: 'modeChanged', mode: 'fog' });
  assert.equal(fog.selection.checked.size, 0);
  assert.equal(fog.selection.focused, null);
  // Hidden tracks and filters aren't set aside.
  assert.deepEqual([...fog.selection.hidden], ['c']);
  const back = reduce(fog, { type: 'modeChanged', mode: 'normal' });
  assert.deepEqual([...back.selection.checked], ['a']);
  assert.equal(back.selection.focused, 'b');
  assert.equal(back.modeSnapshot, null);
});

test('a list read in Fog drops what Normal set aside of rows it no longer has', () => {
  const start = withSelection({ checked: new Set(['a', 'b']), focused: 'c' });
  const back = reduce(start, { type: 'modeChanged', mode: 'fog' }, { type: 'listLoaded', ids: ['a'] }, { type: 'modeChanged', mode: 'normal' });
  assert.deepEqual([...back.selection.checked], ['a']);
  assert.equal(back.selection.focused, null);
});

test('tracks removed in Fog leave what Normal set aside', () => {
  const start = withSelection({ checked: new Set(['a', 'b']), focused: 'b' });
  const back = reduce(start, { type: 'modeChanged', mode: 'fog' }, { type: 'tracksRemoved', ids: ['b'] }, { type: 'modeChanged', mode: 'normal' });
  assert.deepEqual([...back.selection.checked], ['a']);
  assert.equal(back.selection.focused, null);
});

test('a Trip opened in Fog clears what Normal set aside', () => {
  const start = withSelection({ checked: new Set(['a']), focused: 'b' });
  const back = reduce(start, { type: 'modeChanged', mode: 'fog' }, { type: 'tripEntered', id: 's1' }, { type: 'modeChanged', mode: 'normal' });
  assert.equal(back.selection.checked.size, 0);
  assert.equal(back.selection.focused, null);
});

test('the same mode changes nothing', () => {
  const start = withSelection({ checked: new Set(['a']) });
  assert.equal(reduce(start, { type: 'modeChanged', mode: 'normal' }), start);
});

test('viewing a day sets Dates to it and flies there, keeping the selection', () => {
  const next = reduce(withSelection({ checked: new Set(['a']) }), { type: 'dayViewed', day: '2026-10-05' });
  assert.deepEqual(next.dates, { after: '2026-10-05', before: '2026-10-05' });
  assert.equal(next.flyRequest, true);
  assert.deepEqual([...next.selection.checked], ['a']);
});

test('removed tracks leave the selection; an unrelated removal keeps the state', () => {
  const start = withSelection({ checked: new Set(['a', 'b']), focused: 'a', hidden: new Set(['a']) });
  const next = reduce(start, { type: 'tracksRemoved', ids: ['a'] });
  assert.deepEqual([...next.selection.checked], ['b']);
  assert.equal(next.selection.focused, null);
  assert.equal(next.selection.hidden.size, 0);
  assert.equal(reduce(start, { type: 'tracksRemoved', ids: ['x'] }), start);
});

test('removing from the open Trip only drops the focus', () => {
  const start = withSelection({ checked: new Set(['a']), focused: 'a' });
  const next = reduce(start, { type: 'tracksRemoved', ids: ['a'], unfocusOnly: true });
  assert.equal(next.selection.focused, null);
  assert.deepEqual([...next.selection.checked], ['a']);
});

test('Show/Hide acts on the toolbar target', () => {
  const start = withSelection({ focused: 'f' });
  assert.deepEqual([...reduce(start, { type: 'visibilityToggled' }).selection.hidden], ['f']);
  const checked = withSelection({ checked: new Set(['a', 'b']), focused: 'f', hidden: new Set(['a']) });
  assert.equal(reduce(checked, { type: 'visibilityToggled' }).selection.hidden.size, 0);
});

test('a flight is consumed once', () => {
  const flying = reduce(initialSession(null), { type: 'tripEntered', id: 's' });
  assert.equal(flying.flyRequest, true);
  const done = reduce(flying, { type: 'flyConsumed' });
  assert.equal(done.flyRequest, false);
  assert.equal(reduce(done, { type: 'flyConsumed' }), done);
});
