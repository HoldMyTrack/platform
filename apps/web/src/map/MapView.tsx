import { Suspense, useCallback, useEffect, useMemo, useReducer, useRef, useState } from 'react';
import 'maplibre-gl/dist/maplibre-gl.css';
import { listQuery, tracksQuery as tracksQueryFor } from './trackQuery.ts';
import { areaLoad } from './areaLoad.ts';
import { flyToBBox, unionBBox } from './bbox.ts';
import { mapTapsAct } from './exportFlow.ts';
import type { MapMode } from './mapMode.ts';
import { setMapTapsActive } from './mapTaps.ts';
import { initialSession, mapSessionReducer } from './session.ts';
import { setListedTracks } from './tracks.ts';
import { boldTracks, toolbarTarget } from './selection.ts';
import { initialPanelTab, tripParam } from './tripUrl.ts';
import type { SpotCategory } from './spots.ts';
import { useAreaList } from './useAreaList.ts';
import { useCoverageRefresh } from './useCoverageRefresh.ts';
import { useDatesFlight } from './useDatesFlight.ts';
import { useDataRefresh } from './useDataRefresh.ts';
import { useEditWindow } from './useEditWindow.ts';
import { ConfirmDialog } from '../ui/ConfirmDialog.tsx';
import { selectionKept } from './editWindowRows.ts';
import { useExportFlow } from './useExportFlow.ts';
import { satelliteLook } from './satelliteStatus.ts';
import { useFileDrop } from './useFileDrop.ts';
import { useHashSync, useInitialView } from './useInitialView.ts';
import { useListView } from './useListView.ts';
import { useListFlight } from './useListFlight.ts';
import { useMapInstance } from './useMapInstance.ts';
import { useMapLayers } from './useMapLayers.ts';
import { useOpeningView } from './useOpeningView.ts';
import { useOverlays } from './useOverlays.ts';
import { usePendingPoll } from './usePendingPoll.ts';
import { usePhotoLayer } from './usePhotoLayer.ts';
import { useSelectionActions } from './useSelectionActions.ts';
import { useSelectionLayers } from './useSelectionLayers.ts';
import { useSpots } from './useSpots.ts';
import { useTripNav } from './useTripNav.ts';
import { useRouteMetrics } from './useRouteMetrics.ts';
import { useViewOnMap } from './useViewOnMap.ts';
import type { Track } from '../api.ts';
import { useAuth } from '../auth/AuthContext.tsx';
import { TracksPanel, type PanelTab } from '../ui/TracksPanel.tsx';
import type { EditWindowResult } from '../ui/EditTrackWindow.tsx';
import { MapControls } from '../ui/MapControls.tsx';
import { PhotoPopup } from '../ui/PhotoPopup.tsx';
import { SpotPopup } from '../ui/SpotPopup.tsx';
import { todayIn } from '../ui/dateMath.ts';
import { ALL_TIME, dateFilterBounds, setDateFilter } from '../ui/dateFilter.ts';
import { useUnitSystem } from '../ui/units.ts';
import { useHistoryStart } from '../ui/useHistoryStart.ts';
import { showsFirstRun } from '../ui/firstRun.ts';
import { DemoBar } from '../ui/DemoBar.tsx';
import { useTrackList } from '../ui/useTrackList.ts';
import { useTrips } from '../ui/useTrips.ts';
import { useTrip } from '../ui/useTrip.ts';
import { useTour } from '../ui/tour/useTour.ts';
import { t } from '../i18n/index.ts';
import { MapExport } from '../ui/MapExport.tsx';
import { TourLayer } from '../ui/tour/Tour.tsx';
import { lazyChunk } from '../lazyChunk.ts';

interface MapViewProps {
  /** Mount with the Tracks panel on its Privacy tab: `/?private-locations` (App.tsx). */
  initialPrivateLocationsOpen?: boolean;
  /** Mount on one track, its day selected and it focused: `/?track=&day=`, the /sync page's "View on map". */
  initialTrack?: { id: string; day: string } | null;
  /** Start the tour once the map is ready: `/?tour`, the header's Take a tour from another page. */
  initialTour?: boolean;
}

// Loaded when first opened, not with the map: the Edit window, with the route editor and photo
// preparation, is a large part of the app that most visits never open (lazyChunk.ts).
const EditTrackWindow = lazyChunk(() => import('../ui/EditTrackWindow.tsx').then((m) => m.EditTrackWindow));

/** The Edit window's place while its tracks, or its code, are on their way. */
function EditWindowLoading() {
  return (
    <section className="edit-route edit-window" aria-busy="true" data-testid="edit-window-loading">
      <p className="tracks-panel__note" role="status">{t('common.loading')}</p>
    </section>
  );
}

/**
 * The map page: the map and its layers, the Tracks panel beside it, and the Edit window, the
 * export and the popups over it. It composes the map's state (session.ts) with each feature's
 * hook; the hooks are called in the order their effects must run.
 */
export function MapView({ initialPrivateLocationsOpen = false, initialTrack = null, initialTour = false }: MapViewProps) {
  // A demo account is read-only (docs/SPEC.md FR-2.1); `'email' in user` tells a DemoUser from an AuthUser.
  const { user } = useAuth();
  const isDemo = !('email' in user);

  const { initial, flavor, pinned } = useInitialView();

  const container = useRef<HTMLDivElement>(null);
  // The area and Dates or the Trip shown, the selection over it and the mode (session.ts).
  const [session, dispatch] = useReducer(mapSessionReducer, null, () => initialSession(tripParam(window.location.search)));
  const { dates, area, tripId, mode: mapMode } = session;
  const { checked: checkedTrackIds, focused: focusedTrackId, hidden: hiddenTrackIds, excludedTypes, distanceFilter } = session.selection;
  const { overlays, change: changeOverlays, paths, roads, satelliteAvailable, satellite } = useOverlays();

  // The account's today (FR-1.7), read again on every render: a tab left open runs past midnight.
  const today = todayIn(user.timezone);

  // The row or track under the pointer, from either surface, so one effect owns the map's hover
  // feature-state. A preview only: it never moves the camera.
  const [hoveredTrackId, setHoveredTrackId] = useState<string | null>(null);

  // Bumped when a reprocess finishes, so the bands refetch against the new points.
  const [routeMetricsVersion, setRouteMetricsVersion] = useState(0);
  const bumpMetrics = useCallback(() => setRouteMetricsVersion((v) => v + 1), []);

  // The panel's tab lives here so `/?private-locations` (FR-7.1) and `/?trip=` (FR-13.6) can open
  // on it, and so it survives the panel unmounting in Fog.
  const [panelTab, setPanelTab] = useState<PanelTab>(() =>
    initialPanelTab(window.location.search, initialTrack !== null, initialPrivateLocationsOpen),
  );

  const tripState = useTrip(tripId);
  const tripsList = useTrips(panelTab === 'trips');

  const boldIds = useMemo(() => boldTracks(checkedTrackIds, focusedTrackId), [checkedTrackIds, focusedTrackId]);
  const toolbarTargetIds = useMemo(() => toolbarTarget(checkedTrackIds, focusedTrackId), [checkedTrackIds, focusedTrackId]);

  // A Trip, or the area under Dates; the tracks take Dates alone (trackQuery.ts).
  const trackQuery = useMemo(() => listQuery(tripId, dates, area), [tripId, dates, area]);

  // Fetched once here so the panel and the drawn tracks agree on the same rows.
  const {
    tracks,
    total: areaTotal,
    loading: tracksLoading,
    error: tracksError,
    reload: reloadTracks,
    loadedKey: tracksLoadedKey,
  } = useTrackList(trackQuery);
  // The first track's day: the Dates pickers' bound and the empty account's panel.
  const { earliest, latest, ready: daysReady, reload: reloadDays } = useHistoryStart();
  const datesBounds = dateFilterBounds(earliest, latest, today);
  const changeDates = useCallback(
    (end: 'after' | 'before', value: string | null) => {
      const { filter, fly } = setDateFilter(dates, end, value, datesBounds);
      dispatch({ type: 'datesSet', dates: filter, fly });
    },
    [dates, datesBounds.min, datesBounds.max],
  );
  const clearDates = useCallback(() => dispatch({ type: 'datesSet', dates: ALL_TIME, fly: false }), []);

  const listedTrackIds = useMemo(() => tracks.map((a) => a.id), [tracks]);
  const edit = useEditWindow(tracks);
  const editOpen = edit.open;
  // A row a fresh list no longer has (deleted elsewhere, left the Trip or the area) leaves the
  // selection, except the Edit window's while it's open; only a list read for the query shown says
  // so. Read through a ref: closing the window is not a new list.
  const editIdsRef = useRef(edit.ids);
  editIdsRef.current = edit.ids;
  useEffect(() => {
    if (trackQuery !== null && tracksLoadedKey === JSON.stringify(trackQuery)) {
      dispatch({ type: 'listLoaded', ids: selectionKept(listedTrackIds, editIdsRef.current) });
    }
  }, [listedTrackIds, tracksLoadedKey, trackQuery]);
  const editingRoute = edit.editingId !== null;
  const spotsShown = useMemo<readonly SpotCategory[]>(
    () => (editingRoute || !overlays.placesEnabled ? [] : overlays.spots),
    [editingRoute, overlays.placesEnabled, overlays.spots],
  );


  const { pendingIds, distanceBounds: trackDistanceBounds, facets, listed: filteredTracks, mapHiddenIds } = useListView(tracks, session.selection, dispatch);

  const unitSystem = useUnitSystem();
  const { map, basemap, imagery } = useMapInstance({
    container,
    initialView: initial.view,
    initialFlavor: initial.flavor,
    initialSatellite: satellite,
    satellite,
    scaleUnit: unitSystem,
  });
  // Failed imagery draws the map as with Satellite off, and its export too (satelliteStatus.ts).
  const satelliteShown = satelliteLook(satellite, imagery);

  // A Trip's photos change with its members too.
  const tripMembers = tripState.trip?.trackIds.join(',') ?? '';
  const photoLayer = usePhotoLayer(map, {
    mode: mapMode,
    editWindowIds: edit.ids,
    focusedId: focusedTrackId,
    tripId,
    version: `${routeMetricsVersion}|${tripMembers}`,
    editOpen,
    routeTabShown: editOpen && edit.tab === 'route',
    mapHiddenIds,
  });

  // Flies to the combined bounds of the given tracks; one track is its own bbox.
  const fitToSelection = useCallback(
    (selection: Track[]) => {
      if (!map) return;
      const flyBounds = unionBBox(selection.flatMap((a) => (a.bbox ? [a.bbox] : [])));
      if (flyBounds) flyToBBox(map, flyBounds);
    },
    [map],
  );

  // A mode change never moves the camera.
  const setMapMode = useCallback((mode: MapMode) => dispatch({ type: 'modeChanged', mode }), []);
  const select = useSelectionActions(dispatch, tracks, filteredTracks, checkedTrackIds, toolbarTargetIds, mapHiddenIds, fitToSelection);
  const focusTrack = select.focus;
  const clearFocus = select.clearFocus;
  useViewOnMap(map, initialTrack, { mode: mapMode, tracks }, dispatch, focusTrack);
  const urlView = initial.hash.view != null;
  useOpeningView(map, dispatch, { keepCamera: urlView || tripId !== null || initialTrack !== null, country: user.country, earliest, historyReady: daysReady });
  const zoom = useAreaList(map, dispatch, tripId);
  useDatesFlight(map, dispatch, { flyRequest: session.flyRequest, tripId, dates });
  const areaState = areaLoad(zoom, tracks.length, tripId === null ? areaTotal : null);
  // Past the cap the map draws only the listed tracks, so the map and the list stay one set.
  const listedIds = useMemo(() => (areaState.capped ? tracks.map((a) => a.id) : null), [areaState.capped, tracks]);
  // Past the cap the tiles carry only what starts at or after the oldest listed track: the
  // listed tracks and newer ones beyond the view, instead of the whole history (IMPLEMENTATION.md §4.3).
  const since = areaState.capped ? tracks[tracks.length - 1]?.startedAt : undefined;
  const tracksQuery = useMemo(() => ({ ...tracksQueryFor(tripId, dates), ...(since !== undefined && { since }) }), [tripId, dates, since]);
  useEffect(() => {
    if (map) setListedTracks(map, listedIds);
  }, [map, listedIds]);

  useListFlight(map, {
    tracks,
    loadedKey: tracksLoadedKey,
    tripId,
    flyRequest: session.flyRequest,
    onFlown: () => dispatch({ type: 'flyConsumed' }),
    mapHiddenIds,
    urlView,
    arrivingOnTrack: initialTrack !== null,
    fitTo: fitToSelection,
  });

  const spots = useSpots(map, spotsShown);
  const bands = useRouteMetrics(map, focusedTrackId, routeMetricsVersion, mapHiddenIds, pendingIds);
  const exportScene = useMemo(
    () => ({ flavor, mode: mapMode, tracksQuery, listedIds, hiddenIds: [...mapHiddenIds], boldIds, bands, paths, satellite: satelliteShown, roads, photos: photoLayer.exportPhotos }),
    [flavor, mapMode, tracksQuery, listedIds, mapHiddenIds, boldIds, bands, paths, satelliteShown, roads, photoLayer.exportPhotos],
  );
  const exportStats = useMemo(() => ({ checked: checkedTrackIds, tripId }), [checkedTrackIds, tripId]);
  const exporter = useExportFlow(map, container, exportScene, exportStats);
  const tapsAct = mapTapsAct(exporter.flow);
  useEffect(() => setMapTapsActive(tapsAct), [tapsAct]);
  // An export being framed closes when Edit opens over it.
  const cancelExport = exporter.cancel;
  useEffect(() => {
    if (editOpen) cancelExport();
  }, [editOpen, cancelExport]);
  useSelectionLayers(map, {
    boldIds,
    // Hover isn't exported, and framing doesn't preview.
    hoveredId: tapsAct ? hoveredTrackId : null,
    mapHiddenIds,
    editOpen,
    onFocus: focusTrack,
    onHover: setHoveredTrackId,
    onClickAway: clearFocus,
  });

  // Fog is re-rendered by queued jobs, so after an upload or delete this waits for the account's
  // jobs to drain and then refetches it (useCoverageRefresh.ts). `coverageRendering`
  // drives the notice that they may be incomplete.
  const { watch: watchCoverage, rendering: coverageRendering, explored } = useCoverageRefresh(map);
  const refresh = useDataRefresh(map, {
    tracksQuery,
    reloadTracks,
    reloadDays,
    reloadTrip: tripState.reload,
    watchCoverage,
    bumpMetrics,
  });

  const fileDrop = useFileDrop(!isDemo);

  // Deleted tracks: the upload refresh (the first track's day can change too), once per batch, and
  // their ids dropped from the selection. The focus matters most: left on a deleted id, the bands
  // would keep fetching its metrics.
  const handleTracksDeleted = useCallback(
    (ids: string[]) => {
      refresh.afterImport();
      dispatch({ type: 'tracksRemoved', ids });
    },
    [refresh.afterImport],
  );

  const trips = useTripNav({
    tripId,
    dispatch,
    panelTab,
    setPanelTab,
    trips: tripsList,
    trip: tripState,
    reloadTracks,
    watchCoverage,
    refreshTracks: refresh.refreshTracks,
    afterImport: refresh.afterImport,
    onTrackRemoved: (id) => setHoveredTrackId((hovered) => (hovered === id ? null : hovered)),
  });

  const awaitEdit = usePendingPoll(listedTrackIds, pendingIds, tracksLoading, { reload: reloadTracks, onStarted: refresh.pendingStarted, onFinished: refresh.pendingFinished });

  const openEditWindow = useCallback(
    (group: Track[]) => {
      setHoveredTrackId(null);
      edit.openFor(group);
    },
    [edit.openFor],
  );
  // The Route tab's session (§4.7.7): flies to the track, then TrackEditor owns the map until the window closes.
  const startEditRoute = useCallback(
    (track: Track) => {
      setHoveredTrackId(null);
      edit.startRoute(track.id);
      fitToSelection([track]);
    },
    [edit.startRoute, fitToSelection],
  );
  const closeEditWindow = useCallback(
    ({ saved, routeApplied, photosSaved }: EditWindowResult) => {
      const editedRoute = edit.close();
      if (routeApplied && editedRoute !== null) awaitEdit(editedRoute);
      // A route edit leaves the row Pending; the poll runs until the reprocess lands.
      if (saved) reloadTracks();
      if (photosSaved) photoLayer.photos.reload();
    },
    [edit.close, awaitEdit, reloadTracks, photoLayer.photos.reload],
  );

  // The tour's tab changes replace the Trip's URL, so Back doesn't walk through its steps.
  const tourTab = useCallback((tab: PanelTab) => trips.changePanelTab(tab, 'replace'), [trips.changePanelTab]);
  const tour = useTour({
    map,
    isDemo,
    hasTracks: daysReady && map !== null ? earliest !== null : null,
    requested: initialTour,
    mode: mapMode,
    setMode: setMapMode,
    tab: panelTab,
    setTab: tourTab,
    blocked: editOpen,
  });
  // The user's own picks, which may earn a first-time card; the tour's own mode changes don't.
  const changeMapMode = useCallback(
    (mode: MapMode) => {
      setMapMode(mode);
      tour.notice({ kind: 'mode', mode });
    },
    [setMapMode, tour.notice],
  );
  const changePanelTab = useCallback(
    (tab: PanelTab) => {
      trips.changePanelTab(tab);
      tour.notice({ kind: 'tab', tab });
    },
    [trips.changePanelTab, tour.notice],
  );

  useMapLayers(map, {
    initialFlavor: initial.flavor,
    flavor,
    satellite,
    satelliteLook: satelliteShown,
    roads,
    mode: mapMode,
    editingRoute,
    paths,
    spotsShown,
    tracksQuery,
    mapHiddenIds,
    boldIds,
    bands,
  });
  useHashSync(map, pinned);

  return (
    <div className="app-shell">
      <DemoBar isDemo={isDemo} />
      <div className="app-body">
        {mapMode === 'normal' && (
          // Inert while the Edit window is open: it is over the toolbar's target, which the panel
          // would change or delete under it. display: contents keeps the wrapper out of the layout.
          <div className="edit-route-lock" inert={editOpen}>
            <TracksPanel
              readOnly={isDemo}
              tracks={filteredTracks}
              loading={tracksLoading}
              error={tracksError}
              facets={facets}
              excludedTypes={excludedTypes}
              onToggleType={select.toggleType}
              distanceBounds={trackDistanceBounds}
              distanceFilter={distanceFilter}
              onChangeDistance={select.setDistanceFilter}
              checked={checkedTrackIds}
              targetIds={toolbarTargetIds}
              focusedId={focusedTrackId}
              hoveredId={hoveredTrackId}
              onToggle={select.toggleChecked}
              onFocus={focusTrack}
              onClearFocus={clearFocus}
              onHoverTrack={setHoveredTrackId}
              onClear={select.clearChecked}
              onSelectAll={select.checkAll}
              onInvertSelection={select.invertChecked}
              onShowSelected={select.showTarget}
              hiddenIds={hiddenTrackIds}
              onToggleGroupVisibility={select.toggleGroupVisibility}
              onTracksDeleted={handleTracksDeleted}
              onEdit={openEditWindow}
              onTripCreated={trips.openCreatedTrip}
              onTripAdded={trips.handleTripAdded}
              trips={trips.tripsPanel}
              tab={panelTab}
              onTabChange={changePanelTab}
              sheetOpen={tour.open.sheet === true}
              map={map}
              onPrivateLocationsChanged={refresh.afterPrivateLocations}
              firstRun={showsFirstRun(isDemo, daysReady ? earliest !== null : null)}
              dates={{ value: dates, bounds: datesBounds, earliest, today, onChange: changeDates, onClear: clearDates }}
              outOfReach={tripId === null && areaState.load === 'none'}
            />
          </div>
        )}

        <div
          className={exporter.flow.stage === 'idle' ? 'map-root' : 'map-root map-root--exporting'}
          {...fileDrop.handlers}
        >
          {fileDrop.over && (
            <div className="map-drop" data-testid="map-drop">
              <span className="map-drop__label">{t('map.drop_files')}</span>
            </div>
          )}
          <div ref={container} className="map-canvas" data-testid="map-canvas" />
          {/* Edit owns the map while it's open, as the other controls step aside: an export would
              draw the tracks without the edit, and Escape would reach both. */}
          {map && !editOpen && <MapExport map={map} container={container} exporter={exporter} />}
          {map && edit.tracks && (
            <Suspense fallback={<EditWindowLoading />}>
            <EditTrackWindow
              map={map}
              tracks={edit.tracks}
              knownTypes={facets}
              routeUnavailable={edit.routeBlocker === null ? null : t(edit.routeBlocker)}
              onStartRoute={startEditRoute}
              photosUnavailable={edit.photosBlocker === null ? null : t(edit.photosBlocker)}
              photos={{ photos: photoLayer.photos.photos, error: photoLayer.photos.error, reload: photoLayer.photos.reload, onOverlay: photoLayer.setOverlay }}
              onTabChange={edit.setTab}
              onClose={closeEditWindow}
            />
            </Suspense>
          )}
          {edit.open && !edit.tracks && <EditWindowLoading />}
          {edit.closedNotice && (
            <ConfirmDialog
              title={t('deleted' in edit.closedNotice ? 'edit.deleted_title' : 'edit.unreadable_title')}
              message={'deleted' in edit.closedNotice ? t('edit.deleted_message') : edit.closedNotice.failed}
              confirmLabel={t('common.close')}
              cancelLabel={null}
              onConfirm={async () => {}}
              onClose={edit.dismissClosedNotice}
            />
          )}
          {map && photoLayer.popup && (
            <PhotoPopup
              map={map}
              photos={photoLayer.popup.photos}
              index={photoLayer.popup.index}
              onIndex={photoLayer.showPopupIndex}
              onClose={photoLayer.closePopup}
            />
          )}
          {!editOpen && (
            <MapControls
              map={map}
              mode={mapMode}
              onModeChange={changeMapMode}
              overlays={overlays}
              onOverlaysChange={changeOverlays}
              flavor={flavor}
              satelliteAvailable={satelliteAvailable}
              coverageRendering={coverageRendering}
              explored={explored}
              basemapUnreachable={basemap === 'unreachable'}
              satelliteFailed={satellite && imagery === 'failed'}
              spotsShown={spotsShown}
              layersOpen={tour.open.layers === true}
              placesOpen={tour.open.places === true}
              fogLevelOpen={tour.open.fogLevel === true}
              capped={mapMode === 'normal' && tripId === null && areaState.capped && areaTotal !== null ? { shown: tracks.length, total: areaTotal } : null}
            />
          )}
          {map && spots.openSpot && <SpotPopup map={map} spot={spots.openSpot} capturedAt={spots.capturedAt(spots.openSpot.id)} onClose={spots.closeSpot} />}
        </div>
        {!editOpen && <TourLayer tour={tour} />}
      </div>
    </div>
  );
}
