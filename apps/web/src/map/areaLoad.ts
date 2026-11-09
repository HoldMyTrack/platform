import { SPOTS_IN_AREA_MIN_ZOOM } from './spotsGroup.ts';

/** The zoom from which the web's list follows the map as it moves (docs/SPEC.md FR-5.19); below
 *  it a view can hold a region's history, so the area loads when asked. Places' "Show in this
 *  area" starts at the same zoom, so no zoom offers both buttons. */
export const AREA_AUTO_MIN_ZOOM = SPOTS_IN_AREA_MIN_ZOOM;

/** The most activities one area lists (the server's areaActivitiesLimit). */
export const AREA_LIMIT = 1000;

/**
 * How the list follows the map at `zoom`, and whether the last area's list was cut at the limit,
 * which the map then says (FR-5.19). `listed` and `total` are the last load's; `total` is null
 * before one.
 */
export function areaLoad(zoom: number, listed: number, total: number | null): { load: 'auto' | 'button'; capped: boolean } {
  return { load: zoom >= AREA_AUTO_MIN_ZOOM ? 'auto' : 'button', capped: total !== null && total > listed };
}