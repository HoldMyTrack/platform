// Covers docs/SPEC.md FR-4.2, FR-4.3 and FR-4.4: the layers document every client applies.
import { test } from 'node:test';
import assert from 'node:assert/strict';
// Plain .mjs, like bbox.test.mjs: Node strips the types from the imported .ts module itself.
import { heatPointsRadius } from '../src/map/coverageGroup.ts';
import { bindVars, boundLayer, buildLayers, groupOf, tilePath, viewFor, zoomTier } from '../src/map/mapLayers.ts';

const labels = ['places_locality', 'roads_labels_minor'];
const doc = buildLayers({ flavor: 'light', dark: false, labelIds: labels, tileVersion: 'abcd1234.7' });
const MODES = ['normal', 'fog', 'heatmap'];
const coverage = groupOf(doc, 'coverage');

// Every (layer, property) a view sets, as `kind:layer:property`.
const keys = (view) =>
  ['layout', 'paint'].flatMap((kind) => Object.entries(view[kind]).flatMap(([id, props]) => Object.keys(props).map((p) => `${kind}:${id}:${p}`))).sort();

test('every view sets the same properties, so switching never has to undo one', () => {
  const first = keys(doc.views.plain.normal);
  for (const base of ['plain', 'satellite']) for (const mode of MODES) assert.deepEqual(keys(doc.views[base][mode]), first);
});

test('each mode shows only its own layers', () => {
  const visible = (mode) =>
    Object.entries(viewFor(doc, mode, false).layout)
      .filter(([, props]) => props.visibility === 'visible')
      .map(([id]) => id)
      .sort();
  assert.deepEqual(visible('normal'), []);
  assert.deepEqual(visible('fog'), ['country-fog-fill', 'fog-edge', 'fog-veil', 'region-fog-fill']);
  assert.deepEqual(visible('heatmap'), ['heat-points-circles', 'heatmap-dim']);
});

test('Fog mutes the basemap labels and every other mode restores them', () => {
  for (const mode of MODES) {
    const opacity = mode === 'fog' ? 0.4 : 1;
    for (const id of labels) assert.deepEqual(viewFor(doc, mode, false).paint[id], { 'text-opacity': opacity, 'icon-opacity': opacity });
  }
});

test('imagery takes the dark veil over a light flavor', () => {
  assert.equal(viewFor(doc, 'fog', false).paint['fog-veil']['fill-color'], '#202b25');
  assert.equal(viewFor(doc, 'fog', true).paint['fog-veil']['fill-color'], '#f7f4ec');
  const dark = buildLayers({ flavor: 'dark', dark: true, labelIds: labels, tileVersion: '' });
  assert.equal(viewFor(dark, 'fog', false).paint['fog-veil']['fill-color'], '#f7f4ec');
});

test('a layer is added looking as the plain Normal view leaves it', () => {
  const veil = coverage.layers.find((l) => l.id === 'fog-veil');
  assert.equal(veil.layout.visibility, 'none');
  assert.equal(veil.paint['fill-color'], '#202b25');
  assert.equal(coverage.layers[0].id, 'heatmap-dim');
});

test('every layer draws from a source its group carries, at the tile version', () => {
  for (const group of doc.groups) {
    for (const layer of group.layers) if (layer.source) assert.ok(group.sources[layer.source], layer.id);
  }
  assert.equal(coverage.sources['fog-vector'].tiles, '/tiles/v1/fog-vector/{z}/{x}/{y}.mvt?cv=abcd1234.7');
  assert.equal(tilePath('spots', ''), '/tiles/v1/spots/{z}/{x}/{y}.mvt');
});

test('groups go beneath the labels or on top', () => {
  for (const group of doc.groups) assert.ok(['beneath-labels', 'top'].includes(group.placement), group.id);
});

test('the tiers switch where the Country and Region fills hand over', () => {
  assert.equal(zoomTier(doc.tiers, 2.99), 'country');
  assert.equal(zoomTier(doc.tiers, 3), 'region');
  assert.equal(zoomTier(doc.tiers, 6.99), 'region');
  assert.equal(zoomTier(doc.tiers, 7), 'city');
  const region = coverage.layers.find((l) => l.id === 'region-fog-fill');
  const veil = coverage.layers.find((l) => l.id === 'fog-veil');
  assert.equal(region.maxzoom, veil.minzoom);
  assert.equal(zoomTier([], 3), 'city');
});

test('vars bind with let, the client value over the default, arrays as literals', () => {
  const filter = ['in', ['get', 'id'], ['var', 'hidden']];
  assert.deepEqual(bindVars(filter, ['hidden'], { hidden: ['a'] }, { hidden: [] }), ['let', 'hidden', ['literal', ['a']], filter]);
  assert.deepEqual(bindVars(filter, ['hidden'], {}, { hidden: [] }), ['let', 'hidden', ['literal', []], filter]);
  assert.deepEqual(bindVars(['==', ['var', 't'], 1], ['t'], {}, { t: -1 }), ['let', 't', -1, ['==', ['var', 't'], 1]]);
  assert.equal(bindVars(filter, [], {}, {}), filter);
  const layer = { id: 'x', type: 'line', source: 's', filter, metadata: { 'holdmytrack:vars': { filter: ['hidden'] } } };
  assert.deepEqual(boundLayer(layer, { hidden: ['b'] }, {}).filter, ['let', 'hidden', ['literal', ['b']], filter]);
});

// The expression's stops as [zoom, radius] pairs.
const stops = () => {
  const e = heatPointsRadius();
  const out = [];
  for (let i = 3; i < e.length; i += 2) out.push([e[i], e[i + 1]]);
  return out;
};

test('the heat radius doubles across each zoom and drops back at the next', () => {
  const all = stops();
  const max = coverage.sources['heat-points'].maxzoom;
  for (let i = 1; i < all.length; i++) assert.ok(all[i][0] > all[i - 1][0], 'zooms ascend');
  const r = all[0][1];
  for (let z = 0; z < max; z++) {
    assert.equal(all.find(([zoom]) => zoom === z)[1], r);
    assert.equal(all.find(([zoom]) => zoom === z + 0.999)[1], 2 * r);
  }
  const [prev, last] = all.slice(-2);
  assert.equal(prev[0], max);
  assert.equal(last[1] / prev[1], 2 ** (last[0] - prev[0]));
});

test('the bike paths lift the basemap trails, each kind behind its Layers menu switch', () => {
  const bike = groupOf(doc, 'bike-paths');
  assert.deepEqual(bike.lifts, ['paths_trail', 'paths_track', 'paths_bridges_trail', 'paths_bridges_track']);
  assert.deepEqual(
    bike.layers.map((l) => [l.id, l.metadata['holdmytrack:toggle']]),
    [
      ['bike-paths-mtb', 'mtbTrails'],
      ['bike-paths-shared', 'sharedPaths'],
      ['bike-paths-cycleway', 'bikePaths'],
    ],
  );
  for (const layer of bike.layers) assert.equal(layer.layout.visibility, 'none');
  assert.equal(bike.sources['bike-paths'].minzoom, 9);
  assert.ok(doc.groups.indexOf(bike) > doc.groups.indexOf(coverage), 'over Fog and Heatmap');
});

test('the legend gives every path its color, and a dash where the map dashes it', () => {
  const { legend } = groupOf(doc, 'bike-paths');
  assert.deepEqual(Object.keys(legend).sort(), ['bikePaths', 'mtbTrails', 'sharedPaths', 'tracks', 'trails']);
  assert.deepEqual(legend.bikePaths, { color: '#0b5a85' });
  assert.deepEqual(legend.trails.dash, [2, 1]);
  const white = groupOf(buildLayers({ flavor: 'white', dark: false, labelIds: [], tileVersion: '' }), 'bike-paths');
  assert.deepEqual(white.legend.sharedPaths.dash, [2, 1]);
  assert.deepEqual(white.layers.find((l) => l.id === 'bike-paths-shared').paint['line-dasharray'], ['literal', [2, 1]]);
});
