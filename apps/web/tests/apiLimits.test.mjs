// The limits the web applies before sending (src/limits.ts) are the API contract's, which the
// server's own test checks against its handlers (contract_limits_test.go).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import yaml from 'js-yaml';
import * as limits from '../src/limits.ts';

const api = fileURLToPath(new URL('../../../services/server/api/', import.meta.url));
const load = (file) => yaml.load(readFileSync(api + file, 'utf8'));
const paths = (file) => load(`paths/${file}.yaml`);
const schemas = load('components/schemas.yaml');

const jsonBody = (op) => op.requestBody.content['application/json'].schema;
const multipartBody = (op) => op.requestBody.content['multipart/form-data'].schema;

test('the web applies the limits the API contract declares', () => {
  const activity = jsonBody(paths('activities').activities_id.patch).properties;
  const photos = paths('photos');
  const story = schemas.StoryInput.properties;
  const location = schemas.PrivateLocationInput.properties;
  const cases = [
    ['MAX_ACTIVITY_TYPE_LEN', activity.activity_type.maxLength],
    ['MAX_ACTIVITY_NAME_LEN', activity.name.maxLength],
    ['MAX_ACTIVITY_DESCRIPTION_LEN', activity.description.maxLength],
    ['STORY_MAX_NAME_LEN', story.name.maxLength],
    ['STORY_MAX_DESCRIPTION_LEN', story.description.maxLength],
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