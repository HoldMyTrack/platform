import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_STATE,
  anyFilter,
  mapHref,
  ariaSort,
  emptyReason,
  firstBlocked,
  keepListed,
  libraryUrl,
  pageQuery,
  pager,
  parseLibraryUrl,
  sortBy,
  withFilter,
} from '../src/library/libraryState.ts';
import { attachmentName } from '../src/attachmentName.ts';

test('the URL round-trips the state, its defaults left out', () => {
  assert.equal(libraryUrl(DEFAULT_STATE), '');
  const search = '?sort=distance_asc&page=3&q=lake&exclude=bus%2Cdriving&dmin=5000&dmax=20000&from=2026-01-01&to=2026-02-01&trip=t1';
  const state = parseLibraryUrl(search);
  assert.deepEqual(state, {
    sort: 'distance',
    desc: false,
    page: 3,
    q: 'lake',
    exclude: ['bus', 'driving'],
    distance: { min: 5000, max: 20000 },
    dates: { after: '2026-01-01', before: '2026-02-01' },
    trip: 't1',
  });
  assert.deepEqual(parseLibraryUrl(libraryUrl(state)), state);
});

test('a malformed URL leaves each value at its default', () => {
  assert.deepEqual(parseLibraryUrl('?sort=name_asc&page=0&from=yesterday&dmin=far'), DEFAULT_STATE);
  assert.equal(parseLibraryUrl('?page=x').page, 1);
  assert.equal(parseLibraryUrl('?sort=distance').sort, 'started');
});

test('a Distance with its ends crossed is put the right way round', () => {
  assert.deepEqual(parseLibraryUrl('?dmin=20000&dmax=5000').distance, {
    min: 5000,
    max: 20000,
  });
});

test('a filter, the search or the sort goes back to page 1; the pager keeps the rest', () => {
  const on3 = { ...DEFAULT_STATE, page: 3, q: 'x' };
  assert.equal(withFilter(on3, { q: 'y' }).page, 1);
  assert.equal(sortBy(on3, 'distance').page, 1);
});

test("a column's header sorts by it, largest or newest first, then the other way", () => {
  const byDistance = sortBy(DEFAULT_STATE, 'distance');
  assert.equal(byDistance.desc, true);
  assert.equal(ariaSort(byDistance, 'distance'), 'descending');
  assert.equal(ariaSort(byDistance, 'started'), 'none');
  assert.equal(sortBy(byDistance, 'distance').desc, false);
  assert.equal(sortBy(DEFAULT_STATE, 'started').desc, false);
});

test('the Type filter is sent as the types kept, and leaving every type out asks for nothing', () => {
  const all = ['walking', 'cycling', 'bus'];
  assert.equal(pageQuery(DEFAULT_STATE, all).types, undefined);
  assert.deepEqual(pageQuery({ ...DEFAULT_STATE, exclude: ['bus'] }, all).types, ['walking', 'cycling']);
  assert.equal(pageQuery({ ...DEFAULT_STATE, exclude: all }, all), null);
  // Types not known yet: asked without the Type filter, for the bounds.
  assert.equal(pageQuery({ ...DEFAULT_STATE, exclude: ['bus'] }, []).types, undefined);
  assert.deepEqual(
    pageQuery(
      {
        ...DEFAULT_STATE,
        sort: 'moving',
        desc: false,
        distance: { min: 1, max: 2 },
      },
      all,
    ),
    {
      page: 1,
      sort: 'moving_asc',
      minDistance: 1,
      maxDistance: 2,
    },
  );
});

test('the pager says the rows shown and where it can go', () => {
  assert.deepEqual(pager(1, 250, 100), {
    from: 1,
    to: 100,
    prev: false,
    next: true,
  });
  assert.deepEqual(pager(3, 250, 100), {
    from: 201,
    to: 250,
    prev: true,
    next: false,
  });
  assert.equal(pager(4, 250, 100), null);
  assert.equal(pager(1, 0, 100), null);
});

test('an empty page says why: past the last page whatever the filters, else what matched nothing', () => {
  const search = { ...DEFAULT_STATE, q: 'lake' };
  assert.equal(emptyReason(DEFAULT_STATE, 0, false), 'no_tracks');
  assert.equal(emptyReason({ ...search, page: 2 }, 100, true), 'past_last');
  assert.equal(emptyReason(search, 0, true), 'search');
  assert.equal(emptyReason({ ...search, trip: 't1' }, 0, true), 'search_and_filters');
  assert.equal(emptyReason({ ...DEFAULT_STATE, exclude: ['bus'] }, 0, true), 'filters');
});

test("Download names the first checked track it can't take, in the rows' order", () => {
  const rows = [
    { id: 'a', blocked: null },
    { id: 'b', blocked: 'private' },
    { id: 'c', blocked: 'pending' },
  ];
  assert.equal(firstBlocked(rows, new Set(['a', 'c', 'b'])).id, 'b');
  assert.equal(firstBlocked(rows, new Set(['a'])), null);
});

test('Checked keeps only the rows still listed', () => {
  assert.deepEqual([...keepListed(new Set(['a', 'gone']), [{ id: 'a' }, { id: 'b' }])], ['a']);
});

test("a download's file name comes from Content-Disposition, filename* first", () => {
  assert.equal(attachmentName('attachment; filename=holdmytrack-3-tracks-2026-11-23.zip'), 'holdmytrack-3-tracks-2026-11-23.zip');
  assert.equal(attachmentName(`attachment; filename*=UTF-8''2026-05-01%200800%20Caf%C3%A9.gpx`), '2026-05-01 0800 Café.gpx');
  assert.equal(attachmentName('attachment; filename="Ride.gpx"'), 'Ride.gpx');
  assert.equal(attachmentName(null), 'tracks.gpx');
});

test('a Distance with one end left out sends no bound for it, and the URL keeps it out', () => {
  const state = parseLibraryUrl('?dmin=5000');
  assert.deepEqual(state.distance, { min: 5000, max: Infinity });
  const query = pageQuery(state, []);
  assert.equal(query.minDistance, 5000);
  assert.equal('maxDistance' in query, false);
  assert.equal(libraryUrl(state), '?dmin=5000');
  const upTo = parseLibraryUrl('?dmax=8000');
  assert.equal('minDistance' in pageQuery(upTo, []), false);
  assert.equal(libraryUrl(upTo), '?dmax=8000');
});

test('the count says how many match once any filter or the search is on', () => {
  assert.equal(anyFilter(DEFAULT_STATE), false);
  assert.equal(anyFilter({ ...DEFAULT_STATE, q: 'x' }), true);
  assert.equal(anyFilter({ ...DEFAULT_STATE, trip: 't1' }), true);
  assert.equal(anyFilter({ ...DEFAULT_STATE, sort: 'distance', page: 2 }), false);
});

test('a row leads to the map on its track and day', () => {
  assert.equal(mapHref('a1', '2026-05-03'), '/?track=a1&day=2026-05-03');
});

test('a malformed filename* falls back to the default name, never to its own text', () => {
  assert.equal(attachmentName("attachment; filename*=UTF-8''bad%ZZ"), 'tracks.gpx');
  assert.equal(attachmentName("attachment; filename*=UTF-8''bad%ZZ; filename=\"Ride.gpx\""), 'Ride.gpx');
});
