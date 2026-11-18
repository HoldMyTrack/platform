import type { TrackQuery, AreaQuery, BBox } from '../api.ts';
import type { DateFilter } from '../ui/dateFilter.ts';

/** The Dates filter (docs/SPEC.md FR-5.12) as the server's `from`/`to`, an empty end left out. */
export function datesQuery({ after, before }: DateFilter): TrackQuery {
  return { ...(after !== null && { from: after }), ...(before !== null && { to: before }) };
}

/** What the list reads: the open Trip's tracks (`GET /v2/tracks?trip=`), else the area
 *  under Dates (`GET /v2/tracks/area`, FR-5.11); null until the map has an area to ask about. */
export type ListRequest = { trip: TrackQuery } | { area: AreaQuery };

export function listQuery(tripId: string | null, dates: DateFilter, area: BBox | null): ListRequest | null {
  if (tripId !== null) return { trip: { trip: tripId } };
  if (area === null) return null;
  return { area: { ...datesQuery(dates), bbox: area } };
}

/** What the tracks layer draws: the open Trip, else every track Dates passes; past the cap the
 *  map draws only the listed ones (MapView's allow-list). Tiles have their own envelope, so the
 *  area is the list's alone (IMPLEMENTATION.md §4.3). */
export function tracksQuery(tripId: string | null, dates: DateFilter): TrackQuery {
  return tripId !== null ? { trip: tripId } : datesQuery(dates);
}
