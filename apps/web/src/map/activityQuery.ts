import type { ActivityQuery, AreaQuery, BBox } from '../api';
import type { DateFilter } from '../ui/dateFilter';

/** The Dates filter (docs/SPEC.md FR-5.12) as the server's `from`/`to`, an empty end left out. */
export function datesQuery({ after, before }: DateFilter): ActivityQuery {
  return { ...(after !== null && { from: after }), ...(before !== null && { to: before }) };
}

/** What the list reads: the open Story's activities (`GET /v1/activities?story=`), else the area
 *  under Dates (`GET /v1/activities/area`, FR-5.11); null until the map has an area to ask about. */
export type ListRequest = { story: ActivityQuery } | { area: AreaQuery };

export function listQuery(storyId: string | null, dates: DateFilter, area: BBox | null): ListRequest | null {
  if (storyId !== null) return { story: { story: storyId } };
  if (area === null) return null;
  return { area: { ...datesQuery(dates), bbox: area } };
}

/** What the tracks layer draws: the open Story, else every track Dates passes; past the cap the
 *  map draws only the listed ones (MapView's allow-list). Tiles have their own envelope, so the
 *  area is the list's alone (IMPLEMENTATION.md §4.3). */
export function tracksQuery(storyId: string | null, dates: DateFilter): ActivityQuery {
  return storyId !== null ? { story: storyId } : datesQuery(dates);
}
