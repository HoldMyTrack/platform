import type { MapMode } from './mapMode';
import { ROLE_METADATA, type GroupPart } from './mapLayers.ts';
import { casingColor } from './tracksGroup.ts';

/**
 * The focused activity's pace-colored segments (docs/SPEC.md FR-4.8) as the layers document's
 * `track-bands` group: a GeoJSON source the client fills with one line per run of
 * `GET /v1/activities/{id}/track-metrics`' `bands` (trackBands.ts), over the shared tracks layer,
 * since a vector tile can't carry per-vertex color. Each line carries its `band` index, and the
 * layer colors it, so the colors are the server's alone. One more line, the whole route in recording
 * order with a `route` property, carries the direction arrows: on the runs themselves they would
 * bunch wherever the pace changes often.
 */

export const BANDS_LAYER_ID = 'track-bands-line';
const ARROWS_LAYER_ID = 'track-bands-arrows';

/** Blue (slowest) to red (fastest), one per band of internal/httpapi's paceBandCount. */
const BAND_COLORS = ['#2b6cb0', '#38a169', '#d69e2e', '#dd6b20', '#c53030'];

/** Wider than the selected track (tracksGroup.ts) so it covers the line under it instead of
 *  filtering that track out of the shared tiles. */
const BAND_WIDTH = 6;

/** The chevron each client registers as an SDF image, drawn pointing along +x, so the layer
 *  colors it and line placement turns it to point from the route's start to its end. */
export const ARROW_IMAGE = 'track-arrow';
const ARROW_SPACING = 70;

export function bandsGroup(dark: boolean): GroupPart {
  return {
    group: {
      id: 'track-bands',
      placement: 'beneath-labels',
      sources: { 'track-bands': { type: 'geojson' } },
      layers: [
        {
          id: BANDS_LAYER_ID,
          type: 'line',
          source: 'track-bands',
          filter: ['has', 'band'],
          metadata: { [ROLE_METADATA]: 'pace-bands' },
          layout: { 'line-cap': 'round', 'line-join': 'round' },
          paint: {
            // A match, not ["at", …, ["literal", colors]]: a literal array of strings is typed
            // array<string>, which a color property refuses.
            'line-color': ['match', ['get', 'band'], ...BAND_COLORS.flatMap((color, band) => [band, color]), BAND_COLORS[0]] as never,
            'line-width': BAND_WIDTH,
            'line-opacity': 0.95,
          },
        },
        {
          id: ARROWS_LAYER_ID,
          type: 'symbol',
          source: 'track-bands',
          filter: ['has', 'route'],
          layout: {
            'symbol-placement': 'line',
            'symbol-spacing': ARROW_SPACING,
            'icon-image': ARROW_IMAGE,
            'icon-rotation-alignment': 'map',
            'icon-pitch-alignment': 'map',
            // Neither hidden by the basemap's labels nor hiding them.
            'icon-allow-overlap': true,
            'icon-ignore-placement': true,
          },
          paint: { 'icon-color': casingColor(dark) },
        },
      ],
      // The selected activity's card shows the five steps, slowest first.
      legend: Object.fromEntries(BAND_COLORS.map((color, band) => [`band-${band}`, { color }])),
    },
    // Fog and Heatmap already show where; lines over either read as noise.
    view: (mode: MapMode, dark: boolean) => {
      const shown = { visibility: mode === 'normal' ? 'visible' : 'none' };
      return { layout: { [BANDS_LAYER_ID]: shown, [ARROWS_LAYER_ID]: shown }, paint: { [ARROWS_LAYER_ID]: { 'icon-color': casingColor(dark) } } };
    },
  };
}
