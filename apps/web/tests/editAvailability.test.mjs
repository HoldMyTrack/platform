import { test } from 'node:test';
import assert from 'node:assert/strict';
import { editPhotosBlocker, editTrackBlocker } from '../src/ui/editAvailability.ts';

const activity = (overrides = {}) => ({ id: 'a', trackEdit: null, photos: null, ...overrides });

test('the Track tab needs one activity the server allows', () => {
  assert.equal(editTrackBlocker(null), 'activities.edit_track_check_one');
  assert.equal(editTrackBlocker([activity(), activity({ id: 'b' })]), 'activities.edit_track_check_one');
  assert.equal(editTrackBlocker([activity({ trackEdit: 'pending' })]), 'activities.edit_track_processing');
  assert.equal(editTrackBlocker([activity({ trackEdit: 'private' })]), 'activities.private_title');
  assert.equal(editTrackBlocker([activity({ trackEdit: 'no_original' })]), 'activities.edit_track_no_original');
  assert.equal(editTrackBlocker([activity({ trackEdit: 'bad_times' })]), 'activities.edit_track_bad_times');
  assert.equal(editTrackBlocker([activity()]), null);
});

test('photos need one activity the server allows', () => {
  assert.equal(editPhotosBlocker([activity(), activity({ id: 'b' })]), 'photos.check_one');
  assert.equal(editPhotosBlocker([activity({ photos: 'private' })]), 'activities.private_title');
  assert.equal(editPhotosBlocker([activity({ trackEdit: 'pending' })]), null);
});
