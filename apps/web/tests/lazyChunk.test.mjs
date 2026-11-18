import { test } from 'node:test';
import assert from 'node:assert/strict';
import { CHUNK_RELOAD_GAP_MS, reloadForChunk } from '../src/lazyChunk.ts';

test('a chunk that fails to load reloads the page onto the new build', () => {
  assert.equal(reloadForChunk(null, 1_000_000), true);
  assert.equal(reloadForChunk(1_000_000 - CHUNK_RELOAD_GAP_MS - 1, 1_000_000), true);
});

test('a second failure soon after a reload is thrown, not reloaded again', () => {
  assert.equal(reloadForChunk(1_000_000 - 5_000, 1_000_000), false);
});
