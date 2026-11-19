// The camera arithmetic landing-shots.mjs steers the map with: what to scroll and drag to reach a
// view, from the view the URL hash reports.

/** The camera in a `#map=<zoom>/<lat>/<lon>` hash (src/map/viewState.ts), or null without one. */
export function cameraFromHash(hash) {
  const m = /map=([\d.]+)\/([-\d.]+)\/([-\d.]+)/.exec(hash);
  return m ? { zoom: Number(m[1]), lat: Number(m[2]), lon: Number(m[3]) } : null;
}

/** MapLibre's zoom rate for a mouse wheel: scale = 2 / (1 + e^(-|delta| / 450)) per event. */
const WHEEL_RATE = 1 / 450;
/** One event changes zoom by less than 1, so a larger change takes several. */
export const MAX_WHEEL_STEP = 0.9;

/** The wheel deltaY that changes zoom by dz (|dz| ≤ MAX_WHEEL_STEP); negative zooms in. */
export function wheelDelta(dz) {
  const scale = 2 ** Math.abs(dz);
  const delta = -Math.log(2 / scale - 1) / WHEEL_RATE;
  return dz > 0 ? -delta : delta;
}

/** Web Mercator y in CSS pixels at zoom, 512 px tiles as MapLibre draws them. */
function mercatorY(lat, zoom) {
  const rad = (lat * Math.PI) / 180;
  return ((1 - Math.log(Math.tan(Math.PI / 4 + rad / 2)) / Math.PI) / 2) * 512 * 2 ** zoom;
}

/**
 * How far, in CSS pixels at the current zoom, the target centre lies from the current one: x east,
 * y south. Dragging the map by (-x, -y) brings the target to the centre (the map not rotated).
 */
export function panOffset(current, target) {
  const x = ((target.lon - current.lon) * 512 * 2 ** current.zoom) / 360;
  const y = mercatorY(target.lat, current.zoom) - mercatorY(current.lat, current.zoom);
  return { x, y };
}