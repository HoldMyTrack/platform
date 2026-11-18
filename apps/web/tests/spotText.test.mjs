import { test } from 'node:test';
import assert from 'node:assert/strict';
import { memorialLabel, spotAddress, wikipediaURL } from '../src/ui/spotText.ts';

test("a wikipedia tag links to its language's article", () => {
  assert.equal(wikipediaURL('en:Brandywine Falls'), 'https://en.wikipedia.org/wiki/Brandywine_Falls');
  assert.equal(wikipediaURL('zh-yue:香港'), `https://zh-yue.wikipedia.org/wiki/${encodeURIComponent('香港')}`);
});

test('a tag that would put something else in the host links nowhere', () => {
  assert.equal(wikipediaURL('evil.com/x:y'), null);
  assert.equal(wikipediaURL('en:http://evil.com'), null);
  assert.equal(wikipediaURL('Brandywine Falls'), null);
});

test("Copy address copies OSM's address, else the coordinates", () => {
  assert.equal(spotAddress({ address: '8176 Brandywine Rd', lat: 41.27, lon: -81.56 }), '8176 Brandywine Rd');
  assert.equal(spotAddress({ address: null, lat: 41.2766667, lon: -81.5591 }), '41.276667, -81.559100');
});

test("a memorial type reads as words", () => {
  assert.equal(memorialLabel('war_memorial'), 'War memorial');
  assert.equal(memorialLabel('plaque;statue'), 'Plaque statue');
});
