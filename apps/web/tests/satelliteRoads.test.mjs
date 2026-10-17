import { test } from 'node:test';
import assert from 'node:assert/strict';
import { satelliteRoadLayerIds } from '../src/map/satelliteRoads.ts';

test('the road layers are the basemap roads_* ones, labels included, trails left', () => {
  const layers = [
    { id: 'background' },
    { id: 'earth', source: 'protomaps' },
    { id: 'roads_minor_casing', source: 'protomaps' },
    { id: 'roads_bridges_highway', source: 'protomaps' },
    { id: 'roads_rail', source: 'protomaps' },
    { id: 'paths_trail', source: 'protomaps' },
    { id: 'roads_labels_minor', source: 'protomaps' },
    { id: 'roads_shields', source: 'protomaps' },
    { id: 'places_locality', source: 'protomaps' },
    { id: 'roads_of_some_overlay', source: 'bike-paths' },
  ];
  assert.deepEqual(satelliteRoadLayerIds(layers, 'protomaps'), [
    'roads_minor_casing',
    'roads_bridges_highway',
    'roads_rail',
    'roads_labels_minor',
    'roads_shields',
  ]);
});
