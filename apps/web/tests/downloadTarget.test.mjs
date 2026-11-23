import { test } from 'node:test';
import assert from 'node:assert/strict';
import { downloadBlock, MAX_DOWNLOAD_TRACKS } from '../src/ui/downloadTarget.ts';

const track = (id, extra = {}) => ({ id, pending: false, private: false, ...extra });

test('a target that can be downloaded is not blocked', () => {
  assert.equal(downloadBlock([track('a'), track('b')]), null);
  assert.equal(downloadBlock(Array.from({ length: MAX_DOWNLOAD_TRACKS }, (_, i) => track(String(i)))), null);
});

test('more checked tracks than one download takes blocks it, saying how many', () => {
  const many = Array.from({ length: MAX_DOWNLOAD_TRACKS + 1 }, (_, i) => track(String(i), { pending: i === 0 }));
  assert.deepEqual(downloadBlock(many), { kind: 'too_many', count: MAX_DOWNLOAD_TRACKS + 1 });
});

test('the first Pending track blocks it, then the first entirely inside Private locations', () => {
  const privateTrack = track('h', { private: true });
  const pending = track('p', { pending: true });
  assert.deepEqual(downloadBlock([track('a'), privateTrack, pending]), { kind: 'pending', track: pending });
  assert.deepEqual(downloadBlock([track('a'), privateTrack]), { kind: 'private', track: privateTrack });
});
