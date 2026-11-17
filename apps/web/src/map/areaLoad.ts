import { TRACKS_MIN_ZOOM } from './config.ts';

/** The most activities one area lists, and so its map draws (the server's areaActivitiesLimit). */
export const AREA_LIMIT = 1000;

/**
 * Whether the list follows the map at `zoom` (docs/SPEC.md FR-5.11): from TRACKS_MIN_ZOOM, where
 * tracks are drawn, on every settled move; further out there's nothing on the map to list. And
 * whether the last area's list was cut at the limit, so the map draws only the listed tracks and
 * says so. `listed` and `total` are the last load's; `total` is null before one.
 */
export function areaLoad(zoom: number, listed: number, total: number | null): { load: 'auto' | 'none'; capped: boolean } {
  return { load: zoom >= TRACKS_MIN_ZOOM ? 'auto' : 'none', capped: total !== null && total > listed };
}

/**
 * What a move of the user's does to the list once the map settles at `zoom`: 'load' reads it for
 * the new view, and 'none' leaves it, with no track drawn to list. With the Edit window open it is
 * 'later': the window closes when its activities leave the list (useEditWindow.ts), taking what is
 * unsaved in it, so the list keeps its rows until the window closes and then reads the view the
 * map has.
 */
export function settledMove(zoom: number, editOpen: boolean): 'load' | 'later' | 'none' {
  if (areaLoad(zoom, 0, null).load === 'none') return 'none';
  return editOpen ? 'later' : 'load';
}
