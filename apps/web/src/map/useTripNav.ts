import { useCallback, useEffect, useMemo, useRef, type Dispatch } from 'react';
import type { MapSessionEvent } from './session.ts';
import { tripParam, urlWithTrip, type TripNav } from './tripUrl.ts';
import type { Trip } from '../api.ts';
import type { PanelTab, TripsPanel } from '../ui/TracksPanel.tsx';
import type { TripsState } from '../ui/useTrips.ts';
import type { TripState } from '../ui/useTrip.ts';
import { useTripInbox } from '../ui/useTripInbox.ts';

function moveTripUrl(id: string | null, nav: TripNav) {
  if (nav === 'push') window.history.pushState(null, '', urlWithTrip(window.location, id));
  else if (nav === 'replace') window.history.replaceState(null, '', urlWithTrip(window.location, id));
}

interface TripNavInputs {
  tripId: string | null;
  dispatch: Dispatch<MapSessionEvent>;
  panelTab: PanelTab;
  setPanelTab: (tab: PanelTab) => void;
  trips: TripsState;
  trip: TripState;
  reloadTracks: () => void;
  watchCoverage: (then?: () => void) => void;
  refreshTracks: () => void;
  /** A Trip copy arrived (FR-13.7): new tracks, refreshed as an import is. */
  afterImport: () => void;
  /** A track left the open Trip: its hover preview goes too. */
  onTrackRemoved: (id: string) => void;
}

interface TripNavigation {
  enterTrip: (id: string, nav?: TripNav) => void;
  /** `nav` is how opening or leaving the tab's Trip moves the URL: the tour replaces, so Back skips its steps. */
  changePanelTab: (tab: PanelTab, nav?: TripNav) => void;
  /** A Trip just made with Add to trip's "New trip…" opens on the Trips tab. */
  openCreatedTrip: (trip: Trip) => void;
  /** Tracks added to an existing Trip with Add to trip. */
  handleTripAdded: (trip: Trip) => void;
  tripsPanel: TripsPanel;
}

/**
 * The open Trip (FR-13.6) and the Trips tab: one Trip is always open there, the newest until
 * another is picked, and it's kept in the URL so Back and Forward move between Trips and to and
 * from the tab. Opening or closing one resets the list state as a new range does (session.ts).
 */
export function useTripNav(inputs: TripNavInputs): TripNavigation {
  const { tripId, dispatch, panelTab, setPanelTab, trips, trip, reloadTracks, watchCoverage, refreshTracks, afterImport, onTrackRemoved } = inputs;

  const enterTrip = useCallback(
    (id: string, nav: TripNav = 'push') => {
      dispatch({ type: 'tripEntered', id });
      setPanelTab('trips');
      moveTripUrl(id, nav);
    },
    [dispatch, setPanelTab],
  );
  const exitTrip = useCallback(
    (nav: TripNav = 'push') => {
      dispatch({ type: 'tripExited' });
      moveTripUrl(null, nav);
    },
    [dispatch],
  );
  // Leaving the Trips tab closes its Trip; opening it opens the newest (the effect below), with
  // the history move the tab change asked for.
  const openingNav = useRef<TripNav>('push');
  const changePanelTab = useCallback(
    (next: PanelTab, nav: TripNav = 'push') => {
      if (next !== 'trips' && tripId !== null) exitTrip(nav);
      openingNav.current = nav;
      setPanelTab(next);
    },
    [tripId, exitTrip, setPanelTab],
  );

  const tripsReload = trips.reload;
  const onCopyArrived = useCallback(() => {
    tripsReload();
    afterImport();
  }, [tripsReload, afterImport]);
  const inbox = useTripInbox(panelTab === 'trips', onCopyArrived);

  useEffect(() => {
    if (panelTab !== 'trips' || tripId !== null || !trips.ready) return;
    const newest = trips.trips[0];
    if (newest) enterTrip(newest.id, openingNav.current);
  }, [panelTab, tripId, trips.ready, trips.trips, enterTrip]);

  const navRef = useRef({ tripId, enterTrip, exitTrip, setPanelTab });
  navRef.current = { tripId, enterTrip, exitTrip, setPanelTab };
  useEffect(() => {
    const onPopState = () => {
      const { tripId: current, enterTrip: enter, exitTrip: exit, setPanelTab: setTab } = navRef.current;
      const next = tripParam(window.location.search);
      if (next === current) return;
      if (next !== null) {
        enter(next, 'none');
        return;
      }
      exit('none');
      setTab('tracks');
    };
    window.addEventListener('popstate', onPopState);
    return () => window.removeEventListener('popstate', onPopState);
  }, []);

  const openCreatedTrip = useCallback((created: Trip) => enterTrip(created.id), [enterTrip]);
  // The list reloads for the rows' badges. The server moved the tile version, which only
  // `watchCoverage` brings to this page; without it the Trip could later draw from stale tiles.
  const handleTripAdded = useCallback(
    (added: Trip) => {
      trips.replace(added);
      reloadTracks();
      watchCoverage();
    },
    [trips.replace, reloadTracks, watchCoverage],
  );
  const handleTripEdited = useCallback(
    (edited: Trip) => {
      trips.replace(edited);
      trip.set(edited); // only if it's still the open one (useTrip)
    },
    [trips.replace, trip.set],
  );
  // A deleted Trip's tracks stay. Deleting the open one opens the next newest in its place in
  // history; deleting the last leaves none open.
  const handleTripDeleted = useCallback(
    (id: string) => {
      trips.remove(id);
      if (id !== tripId) return;
      const next = trips.trips.find((s) => s.id !== id);
      if (next) enterTrip(next.id, 'replace');
      else exitTrip('replace');
    },
    [trips.remove, trips.trips, tripId, enterTrip, exitTrip],
  );
  // A track taken out of the open Trip: new totals, the row gone, and the tracks redrawn at
  // the tile version the removal moved to.
  const handleTripTrackRemoved = useCallback(
    (edited: Trip, trackId: string) => {
      handleTripEdited(edited);
      dispatch({ type: 'tracksRemoved', ids: [trackId], unfocusOnly: true });
      onTrackRemoved(trackId);
      reloadTracks();
      watchCoverage(refreshTracks);
    },
    [handleTripEdited, dispatch, onTrackRemoved, reloadTracks, watchCoverage, refreshTracks],
  );

  const tripsPanel: TripsPanel = useMemo(
    () => ({
      trips: trips.trips,
      ready: trips.ready,
      error: trips.error,
      inbox,
      openId: tripId,
      openTrip: trip.trip,
      openError: trip.error,
      onOpen: (id: string) => enterTrip(id),
      onEdited: handleTripEdited,
      onDeleted: handleTripDeleted,
      onTrackRemoved: handleTripTrackRemoved,
    }),
    [trips.trips, trips.ready, trips.error, inbox, tripId, trip.trip, trip.error, enterTrip, handleTripEdited, handleTripDeleted, handleTripTrackRemoved],
  );

  return { enterTrip, changePanelTab, openCreatedTrip, handleTripAdded, tripsPanel };
}
