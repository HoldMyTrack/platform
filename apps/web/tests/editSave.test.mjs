// The Edit window's Save (docs/SPEC.md FR-5.5): what it refuses before writing anything, and
// which tracks' fields it writes.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { saveProblem } from '../src/ui/editSave.ts';
import { EMPTY_DRAFT } from '../src/ui/photoDraft.ts';

const form = (over = {}) => ({ trackType: 'hiking', name: 'Ridge', description: '', mixedTypes: false, photoDraft: EMPTY_DRAFT, ...over });
const photo = (routeAt, caption = '') => ({ key: 'k', name: 'p.jpg', prepared: {}, thumbSrc: '', routeAt, caption });

test('a valid form saves', () => {
  assert.equal(saveProblem(form()), null);
});

test('the Track tab is checked first, in field order, in characters after trimming', () => {
  assert.deepEqual(saveProblem(form({ trackType: '  ' })), { key: 'edit.type_required', tab: 'track' });
  assert.equal(saveProblem(form({ trackType: '', mixedTypes: true })), null);
  assert.equal(saveProblem(form({ trackType: 'ж'.repeat(50) })), null);
  assert.equal(saveProblem(form({ trackType: 'ж'.repeat(51) })).key, 'edit.type_too_long');
  assert.equal(saveProblem(form({ name: ` ${'n'.repeat(200)} ` })), null);
  assert.deepEqual(saveProblem(form({ name: 'n'.repeat(201), description: 'd'.repeat(2001) })), {
    key: 'edit.name_too_long', vars: { max: 200 }, tab: 'track',
  });
  assert.equal(saveProblem(form({ description: 'd'.repeat(2001) })).key, 'edit.description_too_long');
});

test('then the Photos tab: every new photo placed, every caption within its limit', () => {
  assert.deepEqual(saveProblem(form({ photoDraft: { ...EMPTY_DRAFT, added: [photo(null)] } })), { key: 'photos.place_first', tab: 'photos' });
  assert.equal(saveProblem(form({ photoDraft: { ...EMPTY_DRAFT, added: [photo(10, 'c'.repeat(501))] } })).key, 'photos.caption_too_long');
  assert.equal(saveProblem(form({ photoDraft: { ...EMPTY_DRAFT, changed: { p1: { caption: 'c'.repeat(501) } } } })).key, 'photos.caption_too_long');
  assert.equal(saveProblem(form({ photoDraft: { ...EMPTY_DRAFT, changed: { p1: { routeAt: 5 } } } })), null);
  // A Track-tab problem is reported first.
  assert.equal(saveProblem(form({ trackType: '', photoDraft: { ...EMPTY_DRAFT, added: [photo(null)] } })).tab, 'track');
});
