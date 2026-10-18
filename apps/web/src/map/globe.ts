import type { ProjectionSpecification } from 'maplibre-gl';

/** The last zoom drawn as a globe; one zoom further in the map is flat. Out there a flat map
 *  on a wide screen repeats the world, two of every country and of every heat, and a globe
 *  shows each once; from here in, the map is as it always was. */
export const GLOBE_MAX_ZOOM = 3;

/** The web maps' projection (style.ts's `globe`): a globe out to GLOBE_MAX_ZOOM, turning flat
 *  over the next zoom. */
export function globeProjection(): ProjectionSpecification {
  return {
    type: ['interpolate', ['linear'], ['zoom'], GLOBE_MAX_ZOOM, 'vertical-perspective', GLOBE_MAX_ZOOM + 1, 'mercator'],
  };
}

/** How much of the viewport's shorter side the globe still fills zoomed all the way out. */
const GLOBE_MIN_FILL = 0.8;

/** MapLibre's world at zoom 0, in CSS pixels. */
const WORLD_SIZE_PX = 512;

/**
 * The web map's minZoom for a `width` × `height` viewport and a vertical field of view of
 * `fovDegrees`: the zoom whose globe spans GLOBE_MIN_FILL of the shorter side, never past
 * GLOBE_MAX_ZOOM so the globe stays reachable. The map is never tilted, and the geometry assumes it.
 *
 * MapLibre's camera sits d = height / (2·tan(fov / 2)) above the globe's near point, so the disc it
 * sees is smaller than the globe: a radius R draws as r = d·R / √(d² + 2dR), solved here for R.
 * MapLibre holds minZoom at the equator, where R = WORLD_SIZE_PX · 2^z / 2π, and keeps that size
 * as the centre moves, so the floor holds at every latitude.
 */
export function globeMinZoom(width: number, height: number, fovDegrees: number): number {
  const side = Math.min(width, height);
  if (!(side > 0)) return 0;
  const r = (GLOBE_MIN_FILL * side) / 2;
  const d = height / (2 * Math.tan((fovDegrees * Math.PI) / 360));
  const radius = (r * r + r * Math.sqrt(r * r + d * d)) / d;
  return Math.min(Math.log2((2 * Math.PI * radius) / WORLD_SIZE_PX), GLOBE_MAX_ZOOM);
}
