import type { PanelTab } from '../ui/TracksPanel.tsx';

/** The open Trip in the URL (FR-13.6), kept there so a refresh or a shared link returns to it. */

/** `?trip=<id>`, or null. */
export function tripParam(search: string): string | null {
  return new URLSearchParams(search).get('trip') || null;
}

/** `?tab=trips` opens the Trips tab with no Trip picked; the copy-arrived email links here (FR-13.7). */
export function tripsTabParam(search: string): boolean {
  return new URLSearchParams(search).get('tab') === 'trips';
}

/** The panel's tab on mount: Tracks for an arriving track, Trips for `?trip=` or
 *  `?tab=trips`, Privacy for `/?private-locations` (FR-7.1). */
export function initialPanelTab(search: string, arrivingOnTrack: boolean, privateLocationsOpen: boolean): PanelTab {
  if (arrivingOnTrack) return 'tracks';
  if (tripParam(search) !== null || tripsTabParam(search)) return 'trips';
  return privateLocationsOpen ? 'private' : 'tracks';
}

/** The URL with `?trip=` set, or removed for null; the hash and other parameters kept. */
export function urlWithTrip(location: { pathname: string; search: string; hash: string }, id: string | null): string {
  const params = new URLSearchParams(location.search);
  if (id === null) params.delete('trip');
  else params.set('trip', id);
  const qs = params.toString();
  return location.pathname + (qs ? `?${qs}` : '') + location.hash;
}

/** What opening or closing a Trip does to history: push, replace, or nothing (Back/Forward already moved it). */
export type TripNav = 'push' | 'replace' | 'none';
