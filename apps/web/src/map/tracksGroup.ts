import type { LayerSpecification } from 'maplibre-gl';
import { TRACKS_MIN_ZOOM } from './config.ts';
import type { MapMode } from './mapMode';
import { ARROW_IMAGE } from './bandsGroup.ts';
import { ROLE_METADATA, tilePath, VARS_METADATA, type GroupPart } from './mapLayers.ts';

/**
 * The account's track lines (IMPLEMENTATION.md §4.3) as the layers document's `tracks` group:
 * every line, the focused one bold over a halo, and the hovered one widest, each its own
 * layer filtered by id set, since MapLibre Native Android has no feature-state. The client binds
 * the sets as vars and appends its own query (the range or Story) to the tiles.
 */

export const TRACKS_LAYER_ID = 'tracks-line';

/** Must match ST_AsMVT(t, 'tracks', ...) in internal/httpapi's tracks query. */
const TRACKS_SOURCE_LAYER = 'tracks';

const TRACK_COLOR = '#b07e2e'; // --fm-accent
const HOVER_COLOR = '#93691f'; // --fm-accent-strong
// The opposite of the basemap: ink over a light map, whose white streets a white halo disappears
// into; a muted grey over a dark map or imagery, where ink does and cream glares.
const LIGHT_CASING = '#202b25';
const DARK_CASING = '#a39e93';
const casingColor = (dark: boolean) => (dark ? DARK_CASING : LIGHT_CASING);
const NORMAL_WIDTH = 2.5;
const FOCUSED_WIDTH = 4.5;
const HOVER_WIDTH = 5;
// 1.5 px of halo showing on each side of the focused line.
const CASING_WIDTH = FOCUSED_WIDTH + 3;

// The pace bands' chevron (bandsGroup.ts) along every bold track: white, since ink on the line
// merges with the halo around it, and larger than on the bands.
const ARROWS_LAYER_ID = 'tracks-arrows';
const ARROW_SPACING = 50;
const ARROW_COLOR = '#ffffff';
const ARROW_SCALE = 1.4;

const LAYER_IDS = ['tracks-casing', TRACKS_LAYER_ID, 'tracks-focused', 'tracks-hover', ARROWS_LAYER_ID];

const notHidden = ['!', ['in', ['get', 'id'], ['var', 'hidden']]];
const among = (set: string) => ['all', ['in', ['get', 'id'], ['var', set]], notHidden];

function line(id: string, filter: unknown[], vars: string[], paint: Record<string, unknown>, role?: string): LayerSpecification {
  return {
    id,
    type: 'line',
    source: 'tracks',
    'source-layer': TRACKS_SOURCE_LAYER,
    minzoom: TRACKS_MIN_ZOOM,
    filter: filter as never,
    layout: { 'line-cap': 'round', 'line-join': 'round' },
    paint,
    metadata: { [VARS_METADATA]: { filter: vars }, ...(role && { [ROLE_METADATA]: role }) },
  } as LayerSpecification;
}

/** Which way each bold track went, pointing from its start to its end: the tiles keep each
 *  line's recorded point order. Under the pace bands, whose own arrows cover the focused one. */
function arrows(): LayerSpecification {
  return {
    id: ARROWS_LAYER_ID,
    type: 'symbol',
    source: 'tracks',
    'source-layer': TRACKS_SOURCE_LAYER,
    minzoom: TRACKS_MIN_ZOOM,
    filter: among('focused') as never,
    layout: {
      'symbol-placement': 'line',
      'symbol-spacing': ARROW_SPACING,
      'icon-image': ARROW_IMAGE,
      'icon-size': ARROW_SCALE,
      'icon-rotation-alignment': 'map',
      'icon-pitch-alignment': 'map',
      // Neither hidden by the basemap's labels nor hiding them.
      'icon-allow-overlap': true,
      'icon-ignore-placement': true,
    },
    paint: { 'icon-color': ARROW_COLOR },
    metadata: { [VARS_METADATA]: { filter: ['focused', 'hidden'] } },
  } as LayerSpecification;
}

/** Bottom to top: the focused track's halo, every track, the focused one, the hovered one, the
 *  bold tracks' arrows. A focused track isn't raised above its neighbours; the halo is what
 *  separates it where tracks overlap. */
export function tracksGroup(dark: boolean, tileVersion: string): GroupPart {
  return {
    group: {
      id: 'tracks',
      placement: 'beneath-labels',
      // MapLibre overzooms a vector source past its maxzoom, so tiles stop at 14 while the map
      // zooms further.
      sources: { tracks: { type: 'vector', tiles: tilePath('tracks', tileVersion), minzoom: 0, maxzoom: 14 } },
      layers: [
        line('tracks-casing', among('focused'), ['focused', 'hidden'], { 'line-color': casingColor(dark), 'line-width': CASING_WIDTH, 'line-opacity': 0.95 }, 'casing'),
        line(TRACKS_LAYER_ID, notHidden, ['hidden'], { 'line-color': TRACK_COLOR, 'line-width': NORMAL_WIDTH, 'line-opacity': 0.9 }, 'track'),
        line('tracks-focused', among('focused'), ['focused', 'hidden'], { 'line-color': TRACK_COLOR, 'line-width': FOCUSED_WIDTH, 'line-opacity': 1 }, 'focused'),
        line('tracks-hover', among('hovered'), ['hovered', 'hidden'], { 'line-color': HOVER_COLOR, 'line-width': HOVER_WIDTH }),
        arrows(),
      ],
    },
    // Fog and Heatmap already show where; lines over either read as noise.
    view: (mode: MapMode, dark: boolean) => ({
      layout: Object.fromEntries(LAYER_IDS.map((id) => [id, { visibility: mode === 'normal' ? 'visible' : 'none' }])),
      paint: { 'tracks-casing': { 'line-color': casingColor(dark) } },
    }),
    vars: { hidden: [], focused: [], hovered: [] },
  };
}
