// The limits the web applies before sending (src/limits.ts) are the API contract's, which the
// server's own test checks against its handlers (contract_limits_test.go).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import * as yaml from 'js-yaml';
import * as limits from '../src/limits.ts';

const api = fileURLToPath(new URL('../../../services/server/api/', import.meta.url));
const load = (file) => yaml.load(readFileSync(api + file, 'utf8'));
const paths = (file) => load(`paths/${file}.yaml`);
const schemas = load('components/schemas.yaml');

const jsonBody = (op) => op.requestBody.content['application/json'].schema;
const multipartBody = (op) => op.requestBody.content['multipart/form-data'].schema;

test('the web applies the limits the API contract declares', () => {
  const track = jsonBody(paths('tracks').tracks_id.patch).properties;
  const photos = paths('photos');
  const trip = schemas.TripInput.properties;
  const location = schemas.PrivateLocationInput.properties;
  const cases = [
    ['MAX_TRACK_TYPE_LEN', track.track_type.maxLength],
    ['MAX_TRACK_NAME_LEN', track.name.maxLength],
    ['MAX_TRACK_DESCRIPTION_LEN', track.description.maxLength],
    ['TRIP_MAX_NAME_LEN', trip.name.maxLength],
    ['TRIP_MAX_DESCRIPTION_LEN', trip.description.maxLength],
    ['MAX_PHOTO_CAPTION_LEN', multipartBody(photos.photos.post).properties.caption.maxLength],
    ['MAX_PHOTO_CAPTION_LEN', jsonBody(photos.photos_id.patch).properties.caption.maxLength],
    ['PRIVATE_LOCATION_MAX_NAME_LEN', location.name.maxLength],
    ['PRIVATE_LOCATION_MIN_RADIUS_M', location.radius_m.minimum],
    ['PRIVATE_LOCATION_MAX_RADIUS_M', location.radius_m.maximum],
  ];
  for (const [name, contract] of cases) {
    assert.equal(limits[name], contract, `${name}: the web has ${limits[name]}, the contract ${contract}`);
  }
});

// The contract states the download's id limit in words, since the ids are one comma-separated
// string; this keeps the web's copy (Download's disabled state) the server's.
test("the web's download limit is the one the contract states", () => {
  const ids = paths('tracks').tracks_gpx.get.parameters.find((p) => p.name === 'ids');
  const stated = Number(/at most (\d+)/.exec(ids.description)?.[1]);
  assert.equal(limits.MAX_DOWNLOAD_TRACKS, stated, `the web has ${limits.MAX_DOWNLOAD_TRACKS}, the contract ${stated}`);
});
