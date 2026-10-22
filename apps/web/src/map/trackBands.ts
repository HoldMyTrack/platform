import type { GeoJSONSource, Map as MapLibreMap } from 'maplibre-gl';
import type { ActivityTrackMetrics } from '../api';

/**
 * Fills the layers document's `track-bands` source (bandsGroup.ts) with the focused activity's
 * pace bands: one line per run the server worked out (`GET /v1/activities/{id}/track-metrics`), each
 * with its `band` index for the layer to color. Neighbouring runs share their boundary point, so
 * the pieces join without a gap.
 */
const BAND_SOURCE_ID = 'track-bands';

const EMPTY = { type: 'FeatureCollection' as const, features: [] };

export function setTrackBands(map: MapLibreMap, metrics: ActivityTrackMetrics): void {
  const source = map.getSource(BAND_SOURCE_ID) as GeoJSONSource | undefined;
  if (!source) return;
  source.setData({
    type: 'FeatureCollection',
    features: metrics.bands.map(({ band, start, end }) => ({
      type: 'Feature',
      properties: { band },
      geometry: {
        type: 'LineString',
        coordinates: metrics.points.slice(start, end + 1).map((p): [number, number] => [p.lon, p.lat]),
      },
    })),
  });
}

/** Called whenever the selection leaves exactly one activity. */
export function clearTrackBands(map: MapLibreMap): void {
  (map.getSource(BAND_SOURCE_ID) as GeoJSONSource | undefined)?.setData(EMPTY);
}
