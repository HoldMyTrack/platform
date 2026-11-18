import { test } from 'node:test';
import assert from 'node:assert/strict';
import { editPhotosBlocker, editRouteBlocker } from '../src/ui/editAvailability.ts';

const track = (overrides = {}) => ({ id: 'a', routeEdit: null, photos: null, ...overrides });

test('the Track tab needs one track the server allows', () => {
  assert.equal(editRouteBlocker(null), 'tracks.edit_route_check_one');
  assert.equal(editRouteBlocker([track(), track({ id: 'b' })]), 'tracks.edit_route_check_one');
  assert.equal(editRouteBlocker([track({ routeEdit: 'pending' })]), 'tracks.edit_route_processing');
  assert.equal(editRouteBlocker([track({ routeEdit: 'private' })]), 'tracks.private_title');
  assert.equal(editRouteBlocker([track({ routeEdit: 'no_original' })]), 'tracks.edit_route_no_original');
  assert.equal(editRouteBlocker([track({ routeEdit: 'bad_times' })]), 'tracks.edit_route_bad_times');
  assert.equal(editRouteBlocker([track()]), null);
});

test('photos need one track the server allows', () => {
  assert.equal(editPhotosBlocker([track(), track({ id: 'b' })]), 'photos.check_one');
  assert.equal(editPhotosBlocker([track({ photos: 'private' })]), 'tracks.private_title');
  assert.equal(editPhotosBlocker([track({ routeEdit: 'pending' })]), null);
});
