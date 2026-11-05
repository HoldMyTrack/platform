// Covers docs/SPEC.md FR-4.2, FR-4.3 and FR-4.4: the layers document every client applies.
import { test } from 'node:test';
import assert from 'node:assert/strict';
// Plain .mjs, like bbox.test.mjs: Node strips the types from the imported .ts module itself.
import { CHEVRON_FONT } from '../scripts/chevronFont.mjs';
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
  assert.deepEqual(visible('normal'), ['track-bands-arrows', 'track-bands-line', 'tracks-arrows', 'tracks-casing', 'tracks-focused', 'tracks-hover', 'tracks-line']);
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

test('the pace bands color each run by its band, shown in Normal only', () => {
  const bands = groupOf(doc, 'track-bands');
  assert.deepEqual(bands.sources, { 'track-bands': { type: 'geojson' } });
  const line = bands.layers.find((l) => l.id === 'track-bands-line');
  assert.deepEqual(line.paint['line-color'].slice(0, 4), ['match', ['get', 'band'], 0, '#2b6cb0']);
  assert.deepEqual(Object.keys(bands.legend), ['band-0', 'band-1', 'band-2', 'band-3', 'band-4']);
  assert.equal(viewFor(doc, 'normal', false).layout['track-bands-line'].visibility, 'visible');
  assert.equal(viewFor(doc, 'fog', false).layout['track-bands-line'].visibility, 'none');
  assert.ok(doc.groups.indexOf(bands) > doc.groups.indexOf(groupOf(doc, 'bike-paths')));
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

test('the tracks draw the focused and hovered ids from vars the client binds, never a hidden one', () => {
  const tracks = groupOf(doc, 'tracks');
  assert.deepEqual(tracks.layers.map((l) => l.id), ['tracks-outline', 'tracks-casing', 'tracks-line', 'tracks-focused', 'tracks-hover', 'tracks-arrows']);
  assert.deepEqual([doc.vars.hidden, doc.vars.focused, doc.vars.hovered], [[], [], []]);
  const focused = tracks.layers.find((l) => l.id === 'tracks-focused');
  assert.deepEqual(focused.metadata['holdmytrack:vars'], { filter: ['focused', 'hidden'] });
  const bound = boundLayer(focused, { focused: ['a'], hidden: ['a'] }, doc.vars).filter;
  assert.deepEqual(bound.slice(0, 5), ['let', 'focused', ['literal', ['a']], 'hidden', ['literal', ['a']]]);
  assert.equal(tracks.layers.find((l) => l.id === 'tracks-line').metadata['holdmytrack:role'], 'track');
  assert.equal(tracks.sources.tracks.tiles, '/tiles/v1/tracks/{z}/{x}/{y}.mvt?cv=abcd1234.7');
  assert.ok(doc.groups.indexOf(tracks) < doc.groups.indexOf(groupOf(doc, 'track-bands')), 'under the bands');
  for (const id of ['tracks-casing', 'tracks-line', 'tracks-arrows']) {
    assert.equal(viewFor(doc, 'normal', false).layout[id].visibility, 'visible');
    assert.equal(viewFor(doc, 'heatmap', false).layout[id].visibility, 'none');
  }
});

test('the focused halo is the opposite of the map under it', () => {
  const casing = (d, satellite) => viewFor(d, 'normal', satellite).paint['tracks-casing']['line-color'];
  const dark = buildLayers({ flavor: 'black', dark: true, labelIds: [], tileVersion: '' });
  assert.deepEqual([casing(doc, false), casing(doc, true), casing(dark, false)], ['#202b25', '#14140e', '#a39e93']);
  assert.equal(groupOf(dark, 'tracks').layers.find((l) => l.id === 'tracks-casing').paint['line-color'], '#a39e93');
});

test('over imagery, every track is bright with a dark outline, and off it nothing changes', () => {
  const dark = buildLayers({ flavor: 'black', dark: true, labelIds: [], tileVersion: '' });
  const tracks = groupOf(doc, 'tracks');
  assert.equal(tracks.layers[0].id, 'tracks-outline');
  assert.equal(tracks.layers[0].layout.visibility, 'none', 'off until a view says otherwise');
  assert.deepEqual(tracks.layers[0].filter, tracks.layers.find((l) => l.id === 'tracks-line').filter);
  for (const d of [doc, dark]) {
    const over = viewFor(d, 'normal', true);
    const plain = viewFor(d, 'normal', false);
    assert.equal(over.layout['tracks-outline'].visibility, 'visible');
    assert.equal(plain.layout['tracks-outline'].visibility, 'none');
    assert.equal(viewFor(d, 'fog', true).layout['tracks-outline'].visibility, 'none');
    for (const id of ['tracks-line', 'tracks-focused']) {
      assert.equal(over.paint[id]['line-color'], '#ffc533');
      assert.equal(plain.paint[id]['line-color'], '#b07e2e');
    }
    assert.deepEqual([over.paint['tracks-hover']['line-color'], plain.paint['tracks-hover']['line-color']], ['#ffe08a', '#93691f']);
    assert.deepEqual([over.paint['tracks-line']['line-opacity'], plain.paint['tracks-line']['line-opacity']], [1, 0.9]);
    assert.deepEqual([over.paint['tracks-arrows']['text-color'], plain.paint['tracks-arrows']['text-color']], ['#14140e', '#ffffff']);
  }
});

test('over imagery, the pace bands are brighter on a dark outline, and off it nothing changes', () => {
  const dark = buildLayers({ flavor: 'black', dark: true, labelIds: [], tileVersion: '' });
  const green = (view) => view.paint['track-bands-line']['line-color'].at(5);
  assert.equal(groupOf(doc, 'track-bands').layers[0].layout.visibility, 'none', 'off until a view says otherwise');
  assert.deepEqual(groupOf(doc, 'track-bands').layers[0].filter, ['has', 'route']);
  for (const d of [doc, dark]) {
    const over = viewFor(d, 'normal', true);
    const plain = viewFor(d, 'normal', false);
    assert.deepEqual([green(over), green(plain)], ['#3df08a', '#38a169']);
    assert.deepEqual([over.layout['track-bands-outline'].visibility, plain.layout['track-bands-outline'].visibility], ['visible', 'none']);
    assert.equal(viewFor(d, 'fog', true).layout['track-bands-outline'].visibility, 'none');
    assert.deepEqual([over.paint['track-bands-arrows']['text-color'], plain.paint['track-bands-arrows']['text-color']], ['#14140e', '#ffffff']);
  }
});

test('arrows ride the route line over the bands, never a band run, as translucent text skipping tight bends, pointing along the line', () => {
  const bands = groupOf(doc, 'track-bands');
  assert.deepEqual(bands.layers.map((l) => l.id), ['track-bands-outline', 'track-bands-line', 'track-bands-arrows']);
  const [, line, arrows] = bands.layers;
  assert.deepEqual([line.filter, arrows.filter], [['has', 'band'], ['has', 'route']]);
  assert.equal(arrows.layout['symbol-placement'], 'line');
  assert.equal(arrows.layout['text-field'], '\uE000\uE000\uE000');
  assert.deepEqual(arrows.layout['text-font'], ['literal', [CHEVRON_FONT]]);
  assert.equal(arrows.layout['text-size'], line.paint['line-width']);
  assert.equal(arrows.layout['text-keep-upright'], false);
  assert.ok(arrows.layout['text-max-angle'] < 45, 'tighter than the default');
  assert.ok(arrows.paint['text-opacity'] > 0 && arrows.paint['text-opacity'] < 1);
  assert.equal(viewFor(doc, 'fog', false).layout['track-bands-arrows'].visibility, 'none');
});

test('the spots go on top, behind one switch, their badges named with the colors to draw them in', () => {
  const spots = groupOf(doc, 'spots');
  assert.equal(spots.placement, 'top');
  assert.equal(doc.groups.at(-1), spots);
  assert.deepEqual(spots.layers.map((l) => l.id), ['spots-area-fill', 'spots-area-line', 'spots-circle-line', 'spots-in-area-icons', 'spots-icons']);
  for (const layer of spots.layers) assert.equal(layer.metadata['holdmytrack:toggle'], 'spots');
  assert.deepEqual(spots.sources['spots-in-area'], { type: 'geojson' });
  const icons = spots.layers.find((l) => l.id === 'spots-icons');
  assert.deepEqual(icons.metadata['holdmytrack:images']['spot-dog_park-captured'], { category: 'dog_park', fill: '#b07e2e', ring: '#7d5820', ink: '#ffffff' });
  assert.equal(Object.keys(icons.metadata['holdmytrack:images']).length, 12);
  assert.deepEqual(icons.metadata['holdmytrack:vars']['icon-image'], ['captured']);
  assert.equal(doc.vars.captureTarget, -1);
  // Fog mutes labels, never the badges.
  for (const base of ['plain', 'satellite']) for (const mode of MODES) assert.equal(doc.views[base][mode].paint['spots-icons'], undefined);
});


test('every bold track carries the pace bands\' arrows, pointing along it, and never a hidden one', () => {
  const arrows = groupOf(doc, 'tracks').layers.find((l) => l.id === 'tracks-arrows');
  const bandArrows = groupOf(doc, 'track-bands').layers.find((l) => l.id === 'track-bands-arrows');
  assert.equal(arrows.layout['text-field'], bandArrows.layout['text-field']);
  const focused = groupOf(doc, 'tracks').layers.find((l) => l.id === 'tracks-focused');
  assert.equal(arrows.layout['text-size'], focused.paint['line-width']);
  assert.deepEqual(arrows.metadata['holdmytrack:vars'], { filter: ['focused', 'hidden'] });
  const tracksFocused = groupOf(doc, 'tracks').layers.find((l) => l.id === 'tracks-focused');
  assert.deepEqual(arrows.filter, tracksFocused.filter);
});