import type { BBox } from '../api';
import { FLY_FILL, unionBBox } from './bbox.ts';

/** The zoom the web's map opens at (docs/SPEC.md FR-4.5): a town or a few valleys. */
export const OPENING_ZOOM = 12;

/** How many of the newest activities the opening view tries to show. */
export const OPENING_ACTIVITIES = 5;

/** MapLibre's tile size: the world is this many px wide at zoom 0. */
const WORLD_PX = 512;

/** Web Mercator's x and y of a point, 0…1 across the world, y down. */
function mercator(lon: number, lat: number): [number, number] {
  const sin = Math.sin((lat * Math.PI) / 180);
  return [(lon + 180) / 360, 0.5 - Math.log((1 + sin) / (1 - sin)) / (4 * Math.PI)];
}

function latitudeAt(y: number): number {
  return (Math.atan(Math.sinh(Math.PI * (1 - 2 * y))) * 180) / Math.PI;
}

/** A longitude within −180…180; 180 itself comes back as −180. */
function wrapped(lon: number): number {
  return ((((lon + 180) % 360) + 360) % 360) - 180;
}

/**
 * The web's opening camera (docs/SPEC.md FR-4.5): zoom 12, centred on the newest five tracks if
 * they fit the screen there, as `flyToBBox` would frame them, else the newest four, and so on;
 * when even the newest alone doesn't fit, still centred on it. `boxes` are the tracks' bounds,
 * newest first; null when there are none.
 */
export function openingView(boxes: readonly BBox[], viewport: { width: number; height: number }): { center: [number, number]; zoom: number } | null {
  const newest = boxes[0];
  if (newest === undefined) return null;
  const scale = WORLD_PX * 2 ** OPENING_ZOOM;
  const frame = (box: BBox) => {
    const [x0, y0] = mercator(box[0], box[3]);
    const [x1, y1] = mercator(box[2], box[1]);
    return { width: (x1 - x0) * scale, height: (y1 - y0) * scale, x: (x0 + x1) / 2, y: (y0 + y1) / 2 };
  };
  let chosen = frame(newest);
  for (let n = Math.min(OPENING_ACTIVITIES, boxes.length); n >= 1; n--) {
    const union = unionBBox(boxes.slice(0, n));
    if (!union) continue;
    const f = frame(union);
    if (f.width <= viewport.width * FLY_FILL && f.height <= viewport.height * FLY_FILL) {
      chosen = f;
      break;
    }
  }
  return { center: [wrapped(chosen.x * 360 - 180), latitudeAt(chosen.y)], zoom: OPENING_ZOOM };
}