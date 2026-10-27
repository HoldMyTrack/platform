import type { GeoJSONSource, Map as MapLibreMap } from 'maplibre-gl';
import type { ActivityTrackMetrics } from '../api';
import { ARROW_IMAGE } from './bandsGroup.ts';

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
  // A style reload drops the image with the layers, and every reload draws the bands again.
  if (!map.hasImage(ARROW_IMAGE)) map.addImage(ARROW_IMAGE, arrowImage(), { pixelRatio: ARROW_PIXEL_RATIO, sdf: true });
  source.setData(bandsData(metrics));
}

const ARROW_PIXEL_RATIO = 2;
/** The chevron's box in CSS px, a little wider than the band it rides. */
const ARROW_SIZE = 14;

/** A white chevron pointing along +x, for the layer to color (bandsGroup.ts). Drawn thicker than it
 *  shows: an SDF image's edge sits at three quarters of its alpha. */
function arrowImage(): ImageData {
  const px = ARROW_SIZE * ARROW_PIXEL_RATIO;
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = px;
  const ctx = canvas.getContext('2d')!;
  ctx.strokeStyle = '#ffffff';
  ctx.lineWidth = px * 0.3;
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  ctx.beginPath();
  ctx.moveTo(px * 0.3, px * 0.18);
  ctx.lineTo(px * 0.7, px * 0.5);
  ctx.lineTo(px * 0.3, px * 0.82);
  ctx.stroke();
  return ctx.getImageData(0, 0, px, px);
}

/** Called whenever the selection leaves exactly one activity. */
export function clearTrackBands(map: MapLibreMap): void {
  (map.getSource(BAND_SOURCE_ID) as GeoJSONSource | undefined)?.setData(EMPTY);
}
