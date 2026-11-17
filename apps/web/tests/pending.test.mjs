import { test } from 'node:test';
import assert from 'node:assert/strict';
import { awaitedByList, pendingChange, unseenLanded } from '../src/map/pending.ts';

const sorted = (set) => [...set].sort();

test('a list speaks for the awaited edits it shows, and not for the others', () => {
  const { shown, unseen } = awaitedByList(new Set(['a', 'b', 'c']), ['b', 'x']);
  assert.deepEqual(sorted(shown), ['b']);
  assert.deepEqual(sorted(unseen), ['a', 'c']);
});

test('an edit saved with its track out of view has not landed by the list that lacks its row', () => {
  const { shown, unseen } = awaitedByList(new Set(['a']), ['x', 'y']);
  const change = pendingChange(new Set(), [], shown);
  assert.equal(change.finished, false);
  assert.deepEqual(sorted(unseen), ['a']);
});

test('an unseen edit lands once the Pending check no longer finds it pending', () => {
  assert.deepEqual(sorted(unseenLanded(new Set(['a']), ['a', 'p'], ['a', 'p'])), []);
  assert.deepEqual(sorted(unseenLanded(new Set(['a']), ['a', 'p'], ['p'])), ['a']);
});

test('only an unseen edit the check was asked about lands by it', () => {
  // `p` is a listed row, which the next list speaks for; `b` wasn't asked about.
  assert.deepEqual(sorted(unseenLanded(new Set(['a', 'b']), ['a', 'p'], [])), ['a']);
});
