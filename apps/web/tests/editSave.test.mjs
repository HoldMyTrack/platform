// The Edit window's Save (docs/SPEC.md FR-5.10): what it refuses before writing anything, and
// which activities' fields it writes.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fieldWrites, saveProblem } from '../src/ui/editSave.ts';
import { EMPTY_DRAFT } from '../src/ui/photoDraft.ts';

const form = (over = {}) => ({ activityType: 'hiking', name: 'Ridge', description: '', mixedTypes: false, photoDraft: EMPTY_DRAFT, ...over });
const photo = (routeAt, caption = '') => ({ key: 'k', name: 'p.jpg', prepared: {}, thumbSrc: '', routeAt, caption });

test('a valid form saves', () => {
  assert.equal(saveProblem(form()), null);
});

test('the Activity tab is checked first, in field order, in characters after trimming', () => {
  assert.deepEqual(saveProblem(form({ activityType: '  ' })), { key: 'edit.type_required', tab: 'activity' });
  assert.equal(saveProblem(form({ activityType: '', mixedTypes: true })), null);
  assert.equal(saveProblem(form({ activityType: 'ж'.repeat(50) })), null);
  assert.equal(saveProblem(form({ activityType: 'ж'.repeat(51) })).key, 'edit.type_too_long');
  assert.equal(saveProblem(form({ name: ` ${'n'.repeat(200)} ` })), null);
  assert.deepEqual(saveProblem(form({ name: 'n'.repeat(201), description: 'd'.repeat(2001) })), {
    key: 'edit.name_too_long', vars: { max: 200 }, tab: 'activity',
  });
  assert.equal(saveProblem(form({ description: 'd'.repeat(2001) })).key, 'edit.description_too_long');
});

test('then the Photos tab: every new photo placed, every caption within its limit', () => {
  assert.deepEqual(saveProblem(form({ photoDraft: { ...EMPTY_DRAFT, added: [photo(null)] } })), { key: 'photos.place_first', tab: 'photos' });
  assert.equal(saveProblem(form({ photoDraft: { ...EMPTY_DRAFT, added: [photo(10, 'c'.repeat(501))] } })).key, 'photos.caption_too_long');
  assert.equal(saveProblem(form({ photoDraft: { ...EMPTY_DRAFT, changed: { p1: { caption: 'c'.repeat(501) } } } })).key, 'photos.caption_too_long');
  assert.equal(saveProblem(form({ photoDraft: { ...EMPTY_DRAFT, changed: { p1: { routeAt: 5 } } } })), null);
  // An Activity-tab problem is reported first.
  assert.equal(saveProblem(form({ activityType: '', photoDraft: { ...EMPTY_DRAFT, added: [photo(null)] } })).tab, 'activity');
});

const walk = { id: 'a', activityType: 'walking', name: 'Walk', description: null };
const ride = { id: 'b', activityType: 'cycling', name: null, description: 'Fast' };

test('one activity writes all three fields, only when something changed', () => {
  assert.deepEqual(fieldWrites([walk], true, 'walking', 'Walk', '', new Map()), []);
  assert.deepEqual(fieldWrites([walk], true, 'hiking', 'Walk', 'Steep', new Map()), [
    { id: 'a', fields: { activityType: 'hiking', name: 'Walk', description: 'Steep' } },
  ]);
});

test('a group writes only the type, keeping each name and description, and an empty type keeps each', () => {
  assert.deepEqual(fieldWrites([walk, ride], false, 'running', '', '', new Map()), [
    { id: 'a', fields: { activityType: 'running', name: 'Walk', description: '' } },
    { id: 'b', fields: { activityType: 'running', name: '', description: 'Fast' } },
  ]);
  assert.deepEqual(fieldWrites([walk, ride], false, '', '', '', new Map()), []);
});

test('a retry after a partial Save writes only what the first one did not', () => {
  const written = new Map([['a', { activityType: 'running', name: 'Walk', description: '' }]]);
  assert.deepEqual(fieldWrites([walk, ride], false, 'running', '', '', written).map((w) => w.id), ['b']);
});