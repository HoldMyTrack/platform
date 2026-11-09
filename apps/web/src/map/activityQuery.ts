import type { ActivityQuery, BBox } from '../api';
import type { DateFilter } from '../ui/dateFilter';

/** The Dates filter (docs/SPEC.md FR-5.20) as the server's `from`/`to`, an empty end left out. */
export function datesQuery({ after, before }: DateFilter): ActivityQuery {
  return { ...(after !== null && { from: after }), ...(before !== null && { to: before }) };
}

/** What the list shows: the open Story, else the area narrowed by Dates (FR-5.19); null until
 *  the map has an area to ask about. */
export function listQuery(storyId: string | null, dates: DateFilter, area: BBox | null): ActivityQuery | null {
  if (storyId !== null) return { story: storyId };
  if (area === null) return null;
  return { ...datesQuery(dates), bbox: area };
}

/** What the tracks layer draws: the open Story, else every track Dates passes. Tiles have their
 *  own envelope, so the area is the list's alone (IMPLEMENTATION.md §4.3). */
export function tracksQuery(storyId: string | null, dates: DateFilter): ActivityQuery {
  return storyId !== null ? { story: storyId } : datesQuery(dates);
}
