import type { LayerSpecification } from 'maplibre-gl';
import { TRACKS_MIN_ZOOM } from './config.ts';
import type { MapMode } from './mapMode';
import { arrowLayout, arrowPaint } from './bandsGroup.ts';
import { ROLE_METADATA, tilePath, VARS_METADATA, type GroupPart } from './mapLayers.ts';

/**
 * The account's track lines (IMPLEMENTATION.md §4.3) as the layers document's `tracks` group:
 * every line, the focused one bold over a halo, and the hovered one widest, each its own
 * layer filtered by id set, since MapLibre Native Android has no feature-state. The client binds
 * the sets as vars and appends its own query (the range or Story) to the tiles.
 */

export const TRACKS_LAYER_ID = 'tracks-line';

/** The hovered track's lines, copied out of the loaded tiles on hover (tracks.ts's setHoveredTrack). */
export const TRACK_HOVER_SOURCE = 'track-hover';

/** Must match ST_AsMVT(t, 'tracks', ...) in internal/httpapi's tracks query. */
export const TRACKS_SOURCE_LAYER = 'tracks';

const TRACK_COLOR = '#b07e2e'; // --fm-accent
const HOVER_COLOR = '#93691f'; // --fm-accent-strong
// The opposite of the basemap: ink over a light map, whose white streets a white halo disappears
// into; a muted grey over a dark map or imagery, where ink does and cream glares.
const LIGHT_CASING = '#202b25';
const DARK_CASING = '#a39e93';
const casingColor = (dark: boolean) => (dark ? DARK_CASING : LIGHT_CASING);
// Imagery can be any color, and the accent nearly vanishes on sand: a bright core reads on dark
// ground, and a dark outline around every track on pale ground.
const SATELLITE_TRACK_COLOR = '#ffc533';
const SATELLITE_HOVER_COLOR = '#ffe08a';
const SATELLITE_EDGE_COLOR = '#14140e';
const TRACK_OPACITY = 0.9;
const OUTLINE_LAYER_ID = 'tracks-outline';
const OUTLINE_OPACITY = 0.8;
const NORMAL_WIDTH = 2.5;
// 1 px of outline showing on each side of a track.
const OUTLINE_WIDTH = NORMAL_WIDTH + 2;
const FOCUSED_WIDTH = 4.5;
const HOVER_WIDTH = 5;
// 1.5 px of halo showing on each side of the focused line.
const CASING_WIDTH = FOCUSED_WIDTH + 3;

// The pace bands' chevrons (bandsGroup.ts) along every bold track.
const ARROWS_LAYER_ID = 'tracks-arrows';

const LAYER_IDS = ['tracks-casing', TRACKS_LAYER_ID, 'tracks-focused', 'tracks-hover', ARROWS_LAYER_ID];

// Drawn: not hidden, and while the web's list was cut at its cap, listed (docs/SPEC.md FR-5.11).
// `capped` defaults to false, so a client that never binds it draws every track.
const notHidden = ['all', ['!', ['in', ['get', 'id'], ['var', 'hidden']]], ['any', ['!', ['var', 'capped']], ['in', ['get', 'id'], ['var', 'listed']]]];
const DRAWN_VARS = ['hidden', 'capped', 'listed'];
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
    layout: arrowLayout(FOCUSED_WIDTH),
    paint: arrowPaint,
    metadata: { [VARS_METADATA]: { filter: ['focused', ...DRAWN_VARS] } },
  } as LayerSpecification;
}

/** Under every track, over imagery only. */
function outline(): LayerSpecification {
  const layer = line(OUTLINE_LAYER_ID, notHidden, DRAWN_VARS, { 'line-color': SATELLITE_EDGE_COLOR, 'line-width': OUTLINE_WIDTH, 'line-opacity': OUTLINE_OPACITY });
  return { ...layer, layout: { ...layer.layout, visibility: 'none' } } as LayerSpecification;
}

/**
 * The hovered track, drawn widest from its own GeoJSON source. A filter by id would be shorter, but
 * MapLibre re-parses a vector source's tiles whenever one of its layers' filters changes, and a
 * pointer moving down the list changed it per row: over 1,000 tracks the highlight trailed the
 * pointer by seconds. A client without hover (Android) leaves the source empty.
 */
function hoverLine(): LayerSpecification {
  return {
    id: 'tracks-hover',
    type: 'line',
    source: TRACK_HOVER_SOURCE,
    minzoom: TRACKS_MIN_ZOOM,
    layout: { 'line-cap': 'round', 'line-join': 'round' },
    paint: { 'line-color': HOVER_COLOR, 'line-width': HOVER_WIDTH },
  } as LayerSpecification;
}

/** Bottom to top: every track's outline over imagery, the focused track's halo, every track, the focused one, the hovered one, the
 *  bold tracks' arrows. A focused track isn't raised above its neighbours; the halo is what
 *  separates it where tracks overlap. */
export function tracksGroup(dark: boolean, tileVersion: string): GroupPart {
  return {
    group: {
      id: 'tracks',
      placement: 'beneath-labels',
      // MapLibre overzooms a vector source past its maxzoom, so tiles stop at 14 while the map
      // zooms further.
      sources: { tracks: { type: 'vector', tiles: tilePath('tracks', tileVersion), minzoom: 0, maxzoom: 14 }, [TRACK_HOVER_SOURCE]: { type: 'geojson' } },
      layers: [
        outline(),
        line('tracks-casing', among('focused'), ['focused', ...DRAWN_VARS], { 'line-color': casingColor(dark), 'line-width': CASING_WIDTH, 'line-opacity': 0.95 }, 'casing'),
        line(TRACKS_LAYER_ID, notHidden, DRAWN_VARS, { 'line-color': TRACK_COLOR, 'line-width': NORMAL_WIDTH, 'line-opacity': TRACK_OPACITY }, 'track'),
        line('tracks-focused', among('focused'), ['focused', ...DRAWN_VARS], { 'line-color': TRACK_COLOR, 'line-width': FOCUSED_WIDTH, 'line-opacity': 1 }, 'focused'),
        hoverLine(),
        arrows(),
      ],
    },
    // Fog already shows where; lines over it read as noise.
    view: (mode: MapMode, dark: boolean, satellite: boolean) => {
      const track = satellite ? SATELLITE_TRACK_COLOR : TRACK_COLOR;
      const shown = { visibility: mode === 'normal' ? 'visible' : 'none' };
      return {
        layout: { ...Object.fromEntries(LAYER_IDS.map((id) => [id, shown])), [OUTLINE_LAYER_ID]: satellite ? shown : { visibility: 'none' } },
        paint: {
          'tracks-casing': { 'line-color': satellite ? SATELLITE_EDGE_COLOR : casingColor(dark) },
          [TRACKS_LAYER_ID]: { 'line-color': track, 'line-opacity': satellite ? 1 : TRACK_OPACITY },
          'tracks-focused': { 'line-color': track },
          'tracks-hover': { 'line-color': satellite ? SATELLITE_HOVER_COLOR : HOVER_COLOR },
          // White on bright gold barely reads.
          [ARROWS_LAYER_ID]: { 'text-color': satellite ? SATELLITE_EDGE_COLOR : arrowPaint['text-color'] },
        },
      };
    },
    vars: { hidden: [], focused: [], capped: false, listed: [] },
  };
}
