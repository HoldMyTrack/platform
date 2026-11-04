import type { MapMode } from './mapMode';
import { ROLE_METADATA, type GroupPart } from './mapLayers.ts';

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

/** The three chevrons on the bands and the bold tracks, as text in their own font
 *  (scripts/chevronFont.mjs): text placed along a line skips what bends past `text-max-angle`, so
 *  they stay off a wiggle too tight to read, and keeps its size at any zoom. `text-size` is the
 *  chevron's width. MapLibre has no blend modes: translucent white shows the color under it as a
 *  lighter shade. */
export const ARROW_FONT = 'HoldMyTrack Chevron';
const ARROW_GROUP = '\uE000\uE000\uE000';
const ARROW_SPACING = 150;
const ARROW_MAX_ANGLE = 25;
const ARROW_OPACITY = 0.7;

export const arrowLayout = (lineWidth: number) => ({
  'symbol-placement': 'line' as const,
  'symbol-spacing': ARROW_SPACING,
  'text-field': ARROW_GROUP,
  // As an expression: Android's document reader takes any array for one.
  'text-font': ['literal', [ARROW_FONT]] as never,
  'text-size': lineWidth,
  'text-max-angle': ARROW_MAX_ANGLE,
  // Upright text would flip to read left to right, pointing some of them backwards.
  'text-keep-upright': false,
  'text-rotation-alignment': 'map' as const,
  'text-pitch-alignment': 'map' as const,
  // Neither hidden by the basemap's labels nor hiding them.
  'text-allow-overlap': true,
  'text-ignore-placement': true,
});
export const arrowPaint = { 'text-color': '#ffffff', 'text-opacity': ARROW_OPACITY };

export function bandsGroup(): GroupPart {
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
          layout: arrowLayout(BAND_WIDTH),
          paint: arrowPaint,
        },
      ],
      // The selected activity's card shows the five steps, slowest first.
      legend: Object.fromEntries(BAND_COLORS.map((color, band) => [`band-${band}`, { color }])),
    },
    // Fog and Heatmap already show where; lines over either read as noise.
    view: (mode: MapMode) => {
      const shown = { visibility: mode === 'normal' ? 'visible' : 'none' };
      return { layout: { [BANDS_LAYER_ID]: shown, [ARROWS_LAYER_ID]: shown }, paint: {} };
    },
  };
}
