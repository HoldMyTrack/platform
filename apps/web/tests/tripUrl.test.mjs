import { test } from 'node:test';
import assert from 'node:assert/strict';
import { initialPanelTab, tripsTabParam, tripParam, urlWithTrip } from '../src/map/tripUrl.ts';

test('the Trip and the Trips tab are read from the query', () => {
  assert.equal(tripParam('?trip=abc&x=1'), 'abc');
  assert.equal(tripParam('?trip='), null);
  assert.equal(tripParam(''), null);
  assert.equal(tripsTabParam('?tab=trips'), true);
  assert.equal(tripsTabParam('?tab=tracks'), false);
});

test('setting and removing the Trip keeps the hash and other parameters', () => {
  const location = { pathname: '/', search: '?x=1', hash: '#12/59.4/24.7' };
  assert.equal(urlWithTrip(location, 's1'), '/?x=1&trip=s1#12/59.4/24.7');
  assert.equal(urlWithTrip({ ...location, search: '?trip=s1' }, null), '/#12/59.4/24.7');
});

test('the panel opens on the tab the URL names, an arriving track first', () => {
  assert.equal(initialPanelTab('?trip=s1', true, true), 'tracks');
  assert.equal(initialPanelTab('?trip=s1', false, true), 'trips');
  assert.equal(initialPanelTab('?tab=trips', false, false), 'trips');
  assert.equal(initialPanelTab('', false, true), 'private');
  assert.equal(initialPanelTab('', false, false), 'tracks');
});
