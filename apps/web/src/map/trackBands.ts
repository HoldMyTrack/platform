import type { GeoJSONSource, Map as MapLibreMap } from 'maplibre-gl';
import type { ActivityTrackMetrics } from '../api';

/**
 * Fills the layers document's `track-bands` source (bandsGroup.ts) with the focused activity's
 * pace bands: one line per run the server worked out (`GET /v1/activities/{id}/track-metrics`), each
 * with its `band` index for the layer to color. Neighbouring runs share their boundary point, so
 * the pieces join without a gap. Then the whole route, for the group's direction arrows.
 */
const BAND_SOURCE_ID = 'track-bands';

const EMPTY = { type: 'FeatureCollection' as const, features: [] };

/** The source's data for `metrics`: a line per band run, then the route in recording order. */
export function bandsData(metrics: ActivityTrackMetrics): GeoJSON.FeatureCollection<GeoJSON.LineString> {
  const line = (points: ActivityTrackMetrics['points'], properties: Record<string, unknown>) => ({
    type: 'Feature' as const,
    properties,
    geometry: { type: 'LineString' as const, coordinates: points.map((p): [number, number] => [p.lon, p.lat]) },
  });
  const runs = metrics.bands.map(({ band, start, end }) => line(metrics.points.slice(start, end + 1), { band }));
  return { type: 'FeatureCollection', features: metrics.points.length < 2 ? runs : [...runs, line(metrics.points, { route: true })] };
}

export function setTrackBands(map: MapLibreMap, metrics: ActivityTrackMetrics): void {
  const source = map.getSource(BAND_SOURCE_ID) as GeoJSONSource | undefined;
  if (!source) return;
  source.setData(bandsData(metrics));
}

/** Called whenever the selection leaves exactly one activity. */
export function clearTrackBands(map: MapLibreMap): void {
  (map.getSource(BAND_SOURCE_ID) as GeoJSONSource | undefined)?.setData(EMPTY);
}
