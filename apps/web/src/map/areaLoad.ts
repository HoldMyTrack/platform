import { TRACKS_MIN_ZOOM } from './config.ts';
import { SPOTS_IN_AREA_MIN_ZOOM } from './spotsGroup.ts';

/** The zoom from which the web's list follows the map as it moves (docs/SPEC.md FR-5.19); below
 *  it a view can hold a region's history, so the area loads when asked. Places' "Show in this
 *  area" starts at the same zoom, so no zoom offers both buttons. */
export const AREA_AUTO_MIN_ZOOM = SPOTS_IN_AREA_MIN_ZOOM;

/** The most activities one area lists (the server's areaActivitiesLimit). */
export const AREA_LIMIT = 1000;

/**
 * How the list follows the map at `zoom` (FR-5.19): on its own from zoom 10, on request below,
 * and not at all where no track is drawn (TRACKS_MIN_ZOOM), since a list of what the map can't
 * show would make no sense. And whether the last area's list was cut at the limit, which the map
 * then says. `listed` and `total` are the last load's; `total` is null before one.
 */
export function areaLoad(zoom: number, listed: number, total: number | null): { load: 'auto' | 'button' | 'none'; capped: boolean } {
  const load = zoom >= AREA_AUTO_MIN_ZOOM ? 'auto' : zoom >= TRACKS_MIN_ZOOM ? 'button' : 'none';
  return { load, capped: total !== null && total > listed };
}