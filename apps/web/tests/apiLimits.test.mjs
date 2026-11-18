// The limits the web applies before sending (src/limits.ts) are the API contract's, which the
// server's own test checks against its handlers (contract_limits_test.go).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import * as yaml from 'js-yaml';
import * as limits from '../src/limits.ts';

const api = fileURLToPath(new URL('../../../services/server/api/v2/', import.meta.url));
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