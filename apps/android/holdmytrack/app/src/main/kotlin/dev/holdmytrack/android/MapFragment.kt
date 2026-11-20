package dev.holdmytrack.android

import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.isVisible
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import android.content.Intent
import android.graphics.RectF
import android.os.Bundle
import android.util.Log
import android.view.View
import dev.holdmytrack.android.export.ExportController
import dev.holdmytrack.android.map.FogPlaces
import dev.holdmytrack.android.map.BasemapStatus
import dev.holdmytrack.android.map.BasemapWatch
import dev.holdmytrack.android.map.BoxUnion
import dev.holdmytrack.android.map.CameraFramer
import dev.holdmytrack.android.map.ChromeInsets
import dev.holdmytrack.android.map.CoverageController
import dev.holdmytrack.android.map.DataRefresh
import dev.holdmytrack.android.map.EmptyNoticeDismissal
import dev.holdmytrack.android.map.LayersController
import dev.holdmytrack.android.map.LocateController
import dev.holdmytrack.android.map.MapChromeRules
import dev.holdmytrack.android.map.MapLayers
import dev.holdmytrack.android.map.MapLayersDoc
import dev.holdmytrack.android.map.MapLayersSource
import dev.holdmytrack.android.map.MapMode
import dev.holdmytrack.android.map.MapNotice
import dev.holdmytrack.android.map.MapOverlays
import dev.holdmytrack.android.map.MapSession
import dev.holdmytrack.android.map.ModeBar
import dev.holdmytrack.android.map.ModeBarState
import dev.holdmytrack.android.map.NoticePanel
import dev.holdmytrack.android.map.PaceBands
import dev.holdmytrack.android.map.AreaController
import dev.holdmytrack.android.map.SatelliteStatus
import dev.holdmytrack.android.map.SatelliteWatch
import dev.holdmytrack.android.map.SessionGate
import dev.holdmytrack.android.map.SheetChrome
import dev.holdmytrack.android.map.SpotsController
import dev.holdmytrack.android.map.StyleMetadata
import dev.holdmytrack.android.map.RouteEditOverlay
import dev.holdmytrack.android.net.Track
import dev.holdmytrack.android.net.Session
import dev.holdmytrack.android.panel.TracksPanel
import dev.holdmytrack.android.panel.TrackTypes
import dev.holdmytrack.android.panel.EditTrackWindow
import dev.holdmytrack.android.panel.EditController
import dev.holdmytrack.android.panel.PanelState
import dev.holdmytrack.android.panel.PanelTab
import dev.holdmytrack.android.panel.PrivateLocationEditor
import dev.holdmytrack.android.panel.SyncTab
import dev.holdmytrack.android.photos.PhotosController
import dev.holdmytrack.android.recording.RecordedPoint
import dev.holdmytrack.android.recording.RecordingController
import dev.holdmytrack.android.recording.RecordingService
import dev.holdmytrack.android.sync.SyncCandidatesController
import dev.holdmytrack.android.sync.SyncProgress
import dev.holdmytrack.android.tour.TourEvent
import dev.holdmytrack.android.tour.TourMenu
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style

/**
 * The map: the served basemap, the session the user layers need, and the Normal / Fog of War
 * toggle floating top-start, as on the web (`apps/web/src/map/MapView.tsx`).
 *
 * In Normal mode the Tracks sheet (`panel/TracksPanel`) lists the visible area's
 * tracks under Dates (`docs/SPEC.md` FR-5.11, FR-5.12, [AreaController]). Tapping a track
 * selects it; tapping empty map clears the selection. On the Trips tab one Trip is open, and
 * the tracks and the list are its tracks only ([AreaController.enterTrip]).
 *
 * GPS recording is controlled from here: the record button in `MainActivity`'s bottom bar taps
 * to start, pause and resume, and a two-second hold stops (`RecordingService` does the rest; its
 * notification's Stop is confirmed here). While recording, the map shows only the live track
 * (`MapOverlays.setRecording`) and the camera follows the latest fix.
 *
 * `MainActivity` adds it only with a session. MapLibre's `MapView` lifecycle is forwarded from
 * this fragment's callbacks.
 */
class MapFragment : Fragment(R.layout.fragment_map) {

    /**
     * What [onViewCreated] builds on the view, held together: null before it and after
     * [onDestroyView], never half-built. A part built early that calls one built later reaches it
     * through [views], which is set once every part exists, so no call site checks a single part.
     */
    private class Views(
        val mapView: MapView,
        val topChrome: View,
        /** The notice under the top row. */
        val notices: NoticePanel,
        /** Whether the session lets the map show the user's layers. */
        val gate: SessionGate,
        /** The Normal / Fog toggle and what it says about the mode. */
        val modes: ModeBar,
        val fogPlaces: FogPlaces,
        /** The Tracks sheet, the list's summary at its head. */
        val sheet: View,
        /** The map image export's viewfinder, from the rail's camera. */
        val export: ExportController,
        val panel: TracksPanel,
        val camera: CameraFramer,
        /** The list for the session's area under Dates or its Trip, Dates' dialog and the cap. */
        val area: AreaController,
        val refresh: DataRefresh,
        val sheetChrome: SheetChrome,
        /** The Edit window and the Private location editor along the bottom of the map. */
        val edit: EditController,
        /** The chrome's and MapLibre's controls' margins against the system bars and the panels. */
        val chrome: ChromeInsets,
        val basemap: BasemapWatch,
        val imagery: SatelliteWatch,
    ) {
        val editWindow: EditTrackWindow get() = edit.window
    }

    private var views: Views? = null

    private val panelState = PanelState()

    /** Fog and every tile kept current with the account's renders and tile version. */
    private val coverage = CoverageController(
        style = { style?.takeIf { overlaysAttached } },
        dates = { session.dates },
        refetchLayers = ::fetchLayers,
        onRenderingChanged = { views?.modes?.renderCoverage() },
    )

    /** The selected track's pace bands. */
    private val bands = PaceBands(
        panelState,
        style = { style?.takeIf { overlaysAttached } },
        onSyncTab = { views?.panel?.tab == PanelTab.SYNC },
        onShown = { views?.panel?.setBands(it) },
        // A reprocess can move a photo along its track, or take its stretch away.
        onRefetch = { photos.refresh(force = true) },
    )

    /** A View on map from the Sync screen ([viewOnMap]), the track and its day, waiting for
     *  the session to be confirmed. */
    private var viewOnMapRequest: Pair<String, String>? = null

    /** Something the Sync tab sent has landed, whichever tab shows: the list, its days and the
     *  tiles catch up. Until then its job is only queued, with no row to show Pending. */
    private val syncProgressListener = SyncProgress.Listener(onChange = {}, onLanded = { onSyncedFromPhone() })
    /** The area and Dates or the Trip the list and tracks show, and whether the camera moves next. */
    private val session = MapSession(panelState)
    private var imageryStatus = SatelliteStatus.LOADING
    private val tripId: String? get() = session.tripId

    /** Set on every resume, since Sync or a recording may have added days; `syncSession`
     *  reloads them once the session allows. */
    private var daysStale = false

    private var map: MapLibreMap? = null
    private var style: Style? = null
    /** The mode the map shows ([MapChromeRules.tabMode]): [pickedMode] on the Tracks tab, else Normal. */
    private var mode = MapMode.NORMAL

    /** The mode picked on the Tracks tab, which comes back there after Trips or Sync. */
    private var pickedMode = MapMode.NORMAL

    /** Whether the user layers are on the style (`syncSession`). */
    private var overlaysAttached = false

    /** The layers document for the style's flavor ([MapLayersSource]), once there is one. */
    private var layersDoc: MapLayersDoc.Doc? = null

    /** The style was loaded again because the layers document named another build: once, so a
     *  server answering two builds can't loop. */
    private var styleReloaded = false

    /** Whether the map view is coming back from a recreation (rotation, theme, language) with
     *  the camera MapLibre saved, which the opening world view mustn't replace. */
    private var restoringCamera = false

    /** Whether `syncSession` has shown the mode toggle. Ending a recording mustn't show it
     *  before the session would have. */
    private var modeBarReady = false

    /** GPS recording: the record button, its status pill, the service binding and the camera's follow. */
    private val recording = RecordingController(
        this,
        onChanged = ::onRecordingChanged,
        styleLoaded = { style != null },
        map = { map },
        showMap = { host?.showMap() },
    )

    /** What the Sync tab has the map draw. */
    private val syncCandidates = SyncCandidatesController(style = { style?.takeIf { overlaysAttached } })

    /** A tab the bottom bar asked for before the panel was built: shown once it is. */
    private var pendingTab: PanelTab? = null

    /** Photos on the map: the scope's markers, their popup and the Photos tab's picker. */
    private val photos = PhotosController(
        this,
        panelState,
        map = { map },
        editWindow = { views?.editWindow },
        mode = { mode },
        tripId = { tripId },
        recording = ::isRecording,
        frame = { box, maxZoom -> views?.camera?.flyTo(box, maxZoom) },
        onPopupOpening = {
            spots.closePopup()
            views?.fogPlaces?.close()
        },
    )

    /** Find my location's dot and tracking camera. */
    private val locate = LocateController(this, map = { map }, style = { style })

    /** Points of interest: the shown places, their badges and popup, and capture mode. */
    private val spots = SpotsController(this, map = { map }, style = { style?.takeIf { overlaysAttached } }, frame = { views?.camera?.flyTo(it) })

    /** The style's flavor and language, the Layers menu's roads, paths and satellite, and the Places menu's places. */
    private val layers = LayersController(this, spots, style = { style }, attached = { overlaysAttached }, mode = { mode }, onSatelliteSwitched = ::onSatelliteSwitched)

    /** The window this map is a tab of; null while the fragment is detached. */
    private val host get() = activity as? MainActivity

    /** The bottom bar's Trips: the panel's Trips tab. */
    fun showTrips() = show(PanelTab.TRIPS)

    /** The bottom bar's Sync: the panel's Sync tab, in Normal mode, where the sheet is. */
    fun showSync() = show(PanelTab.SYNC)

    /**
     * The Privacy screen's Add a location ([PrivateLocationEditor.NEW]) or one of its rows: the
     * editor on the map, in Normal mode. Not while recording, which has the map.
     */
    fun editPrivateLocation(id: String) {
        val edit = views?.edit ?: return
        if (isRecording()) return
        if (pickedMode != MapMode.NORMAL) pickMode(MapMode.NORMAL)
        edit.privacy.start(id)
        edit.privacy.onStyleReady()
    }

    /** The bottom bar's Tracks: the panel's Tracks tab, collapsed. */
    fun showTracks() = show(PanelTab.TRACKS)

    /** [tab] on the panel, or once the panel is built: the bottom bar's mark already says it. */
    private fun show(tab: PanelTab) {
        val panel = views?.panel ?: run {
            pendingTab = tab
            return
        }
        when (tab) {
            PanelTab.TRACKS -> panel.showTracks()
            PanelTab.TRIPS -> panel.showTrips()
            PanelTab.SYNC -> panel.showSync()
        }
    }

    /** Which panel tab shows, for the bottom bar's Trips mark. Null without the view. */
    val panelTab: PanelTab? get() = views?.panel?.tab

    /** The tab showing, Tracks without the view. */
    private val tab: PanelTab get() = panelTab ?: PanelTab.TRACKS

    // What the tour (tour/TourController, through MainActivity) reads and holds on the map.
    val tourMode: MapMode? get() = if (modeBarReady) pickedMode else null
    fun setTourMode(next: MapMode) = pickMode(next)
    val sheetOpen: Boolean get() = views?.panel?.expanded == true
    fun setSheetOpen(open: Boolean) {
        views?.panel?.setExpanded(open)
    }
    /** The tour holds a map menu open, or lets go of it. */
    fun holdMenu(menu: TourMenu, open: Boolean) = when (menu) {
        TourMenu.LAYERS -> layers.hold(open)
        TourMenu.PLACES -> layers.holdPlaces(open)
        TourMenu.FOG_LEVEL -> views?.modes?.holdFogLevel(open) ?: Unit
    }
    val layersMenu: View? get() = layers.menuContent
    val placesMenu: View? get() = layers.placesContent
    val fogLevelMenu: View? get() = views?.modes?.fogLevelContent

    /** Every map menu closed: their popups are windows of their own, outliving the view and drawn over the export. */
    private fun dismissMenus() {
        layers.dismiss()
        views?.modes?.dismissFogLevel()
    }
    val mapLibre: MapLibreMap? get() = map
    val tourBlocked: Boolean get() = !modeBarReady || isRecording() || editOpen() || privacyEditing()

    /** Whether the Edit window is open over the map. */
    private fun editOpen() = views?.editWindow?.isOpen == true

    /** The fragment's own views, found the way an Activity finds its own. */
    private fun <T : View> findViewById(id: Int): T = requireView().findViewById(id)

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        val topChrome = findViewById<View>(R.id.top_chrome)
        val notices = NoticePanel(
            findViewById(R.id.map_notice),
            recording = ::isRecording,
            onSync = { tab == PanelTab.SYNC },
        )
        val gate = SessionGate(this, notices, onChecked = ::syncSession)
        val fogPlaces = FogPlaces(view.findViewById(R.id.fog_place_popup), style = { style?.takeIf { overlaysAttached } }) { topChrome.bottom }
        val modes = ModeBar(
            view,
            onPick = { picked ->
                pickMode(picked)
                host?.tour?.notice(TourEvent.Mode(picked))
            },
            levels = { style?.let(MapLayers::levels).orEmpty() },
            zoom = { map?.cameraPosition?.zoom },
            onLock = { locked, zoomTo ->
                MapLayers.update(style) { it.copy(fogLevel = locked) }
                zoomTo?.let { z -> map?.easeCamera(CameraUpdateFactory.zoomTo(z)) }
                views?.modes?.renderFogLevel()
                // A lock can change the level without moving the camera.
                fogPlaces.onCameraMove()
            },
        ) {
            ModeBarState(
                mode = mode,
                sessionReady = modeBarReady,
                recording = isRecording(),
                editOpen = editOpen(),
                selectionShown = views?.sheetChrome?.selectionShown() == true,
                coverageRendering = coverage.rendering,
                tab = tab,
            )
        }
        layers.bind(view)
        spots.bind(view) { topChrome.bottom }
        photos.bind(view) { topChrome.bottom }
        recording.bind(view)

        locate.bind(view)
        val sheet = findViewById<View>(R.id.tracks_sheet)
        val export = ExportController(
            view,
            map = { map },
            styleLoaded = { style != null },
            style = { style },
            layers = layers,
            prepare = ::prepareExportStyle,
            photos = photos::markersSnapshot,
            checked = { panelState.checked },
            tripId = { tripId },
            chrome = listOf(topChrome, sheet),
            onShown = { shown ->
                renderBottomBar()
                // In sight, as they're in the image, but a tap on one goes to the map.
                photos.setMarkersInteractive(!shown)
                if (shown) {
                    spots.closePopup()
                    photos.closePopup()
                    fogPlaces.close()
                    dismissMenus()
                } else {
                    // The sheet comes back only where it belongs: not in Fog.
                    renderSheet()
                }
            },
        )
        val syncTab = SyncTab(
            findViewById(R.id.panel_sync_content),
            requireActivity() as AppCompatActivity,
            scope = { viewLifecycleOwner.lifecycleScope },
            onCandidates = syncCandidates::set,
            onFrame = { candidates -> BoxUnion.of(candidates.map { it.bbox }.filter { it.isNotEmpty() })?.let { views?.camera?.flyTo(it) } },
            onSynced = ::onSyncedFromPhone,
        )
        val panel = TracksPanel(
            sheet,
            findViewById(R.id.selection_bar),
            panelState,
            onMapChanged = ::applyTrackFilter,
            onFly = { views?.camera?.flyTo(it) },
            onEdit = ::openEditWindow,
            onDeleted = { views?.refresh?.afterDelete(it) },
            onTabChanged = { tab ->
                // Leaving the Trips tab closes its Trip.
                if (tab != PanelTab.TRIPS && tripId != null) views?.area?.exitTrip()
                // Trips and Sync are Normal mode's; the Tracks tab gets its pick back.
                applyTabMode()
                // The summary is the Tracks tab's; renderSheet renders Privacy too.
                renderSheet()
                // The empty map's notice points to Sync, so it steps aside there.
                notices.render()
                // What's already synced steps aside for what's on offer.
                style?.takeIf { overlaysAttached }?.let { MapOverlays.setSyncing(it, tab == PanelTab.SYNC, mode) }
                // The bottom bar's Trips is this tab, so the bar follows it.
                host?.onPanelTabChanged(tab)
            },
            onOpenTrip = { views?.area?.enterTrip(it) },
            onCloseTrip = { views?.area?.exitTrip() },
            // A Trip just made opens straight away, on the Trips tab.
            onTripCreated = { trip -> views?.area?.enterTrip(trip.id) },
            onTripsChanged = {
                views?.area?.reloadList()
                // A Trip's photos change with its members.
                photos.refresh(force = true)
            },
            onRemovedFromTrip = { views?.refresh?.afterRemovedFromTrip(it) },
            // The map has history now, so the empty notice goes.
            onTripCopyArrived = {
                notices.hide(MapNotice.EMPTY)
                views?.refresh?.afterTripCopy()
            },
            onTripsWaiting = { host?.setTripsWaiting(it) },
            onSheetChanged = { views?.sheetChrome?.onSheetChanged() },
            syncTab = syncTab,
        )
        val camera = CameraFramer(view, panel, map = { map }, recording = ::isRecording, onEmpty = ::onEmptyChecked)
        val area = AreaController(
            this,
            sheet,
            session,
            panelState,
            panel,
            map = { map },
            style = { style?.takeIf { overlaysAttached } },
            framer = { camera },
            bands = bands,
            coverage = coverage,
            recording = ::isRecording,
            onSelectionReset = ::applyTrackFilter,
            onCapped = { text -> if (text == null) notices.hide(MapNotice.CAPPED) else notices.show(MapNotice.CAPPED, text) },
        )
        val refresh = DataRefresh(area, session, panel, panelState, style = { style?.takeIf { overlaysAttached } }, coverage, bands, photos)
        val sheetChrome = SheetChrome(
            view,
            panel,
            normalMode = ::normalMode,
            sessionReady = { modeBarReady },
            mode = { mode },
            editOpen = ::editOpen,
            privacyEditing = ::privacyEditing,
            onSheetMoved = { views?.chrome?.applyAttributionMargin() },
            onSelectionBarChanged = ::renderModeBar,
            onRendered = {
                bands.render()
                renderPrivacy()
            },
            dismissLayers = layers::dismiss,
        )
        val mapView = findViewById<MapView>(R.id.map_view)
        val edit = EditController(
            view,
            panelState,
            panel = { panel },
            photos = photos,
            spots = spots,
            map = { map },
            style = { style },
            attached = { style?.takeIf { overlaysAttached } },
            mode = { mode },
            frame = { camera.flyTo(it) },
            openAreaCenterY = {
                val editor = findViewById<View>(R.id.private_editor)
                val top = findViewById<View>(R.id.top_bar).bottom
                val bottom = if (editor.isVisible) editor.top else mapView.height - if (sheet.isVisible) panel.peekHeight else 0
                (top + bottom) / 2f
            },
            onPrivateLocationsChanged = { views?.refresh?.afterPrivateLocations() },
            onWindowChanged = ::onEditWindowChanged,
            onPrivacyChanged = ::onPrivacyEditorChanged,
            onWindowClosed = ::onEditClosed,
        )
        val chrome = ChromeInsets(findViewById(R.id.map_root), findViewById(R.id.top_bar), topChrome, notices.view, sheet, panel) { map }
        // Failures are reported here rather than only in logcat: a style or tile fetch that
        // 404s leaves a plausible-looking blank map behind, with nothing on screen to say so.
        val basemap = BasemapWatch(mapView, ::onBasemap)
        val imagery = SatelliteWatch(mapView, isOn = { layers.satelliteOn }, onChange = ::onImagery)
        views = Views(
            mapView, topChrome, notices, gate, modes, fogPlaces, sheet, export, panel, camera, area, refresh,
            sheetChrome, edit, chrome, basemap, imagery,
        )

        pendingTab?.let { tab ->
            pendingTab = null
            view.post { show(tab) }
        }
        chrome.restore(savedInstanceState)
        requireActivity().onBackPressedDispatcher.addCallback(viewLifecycleOwner, sheetChrome.collapseOnBack)
        // Added after the sheet's, so it's asked first: Back ends selecting before it closes the sheet.
        requireActivity().onBackPressedDispatcher.addCallback(viewLifecycleOwner, sheetChrome.endSelectingOnBack)
        requireActivity().onBackPressedDispatcher.addCallback(viewLifecycleOwner, edit.closeWindowOnBack)
        requireActivity().onBackPressedDispatcher.addCallback(viewLifecycleOwner, edit.closePrivacyOnBack)
        // Last, so it's asked first.
        requireActivity().onBackPressedDispatcher.addCallback(viewLifecycleOwner, export.backCallback)
        area.restore(savedInstanceState)
        // Carried through a recreation (a theme or language change), since the mode buttons
        // restore their own checked state and would otherwise show a mode the map isn't in.
        savedInstanceState?.let { pickedMode = MapChromeRules.restoredMode(it.getString(STATE_MODE)) }
        setMode(MapChromeRules.tabMode(pickedMode, panel.tab))

        chrome.install()
        if (savedInstanceState == null) {
            recording.handleIntent(requireActivity().intent)
            takeViewOnMap(requireActivity().intent)
        }

        restoringCamera = savedInstanceState?.getBoolean(STATE_FRAMED) == true
        // The camera comes back with the view; framing it again would undo where the user was.
        if (restoringCamera) camera.framed = true
        mapView.onCreate(savedInstanceState)
        edit.takeHandleDrags(mapView)

        mapView.addOnDidFailLoadingMapListener { error -> reportFailure(error) }

        mapView.getMapAsync { instance ->
            map = instance
            // A whole-world view is the honest starting camera until the session is verified
            // and the track extent is known; `CameraFramer.open` replaces it with the user's
            // own, and leaves it for an account with no geometry yet. Not over a camera a
            // recreation brought back.
            if (!restoringCamera) {
                instance.cameraPosition = CameraPosition.Builder()
                    .target(LatLng(20.0, 0.0))
                    .zoom(1.0)
                    .build()
            }
            chrome.applyCompassMargin()
            chrome.applyAttributionMargin()
            mapView.post { chrome.enlargeAttributionTarget(mapView) }
            instance.addOnMapClickListener { point -> onMapTap(instance, point) }
            instance.addOnCameraMoveListener {
                spots.onCameraMove()
                photos.onCameraMove()
            }
            instance.addOnCameraIdleListener { photos.onCameraIdle() }
            spots.onMapReady(view, instance, layers.shownSpots())
            instance.addOnCameraIdleListener { spots.onCameraIdle() }
            // The list follows the map (AreaController).
            instance.addOnCameraIdleListener { area.onCameraIdle() }
            // Fog's button names the level in view as the zoom changes; a picked place's popup follows.
            instance.addOnCameraMoveListener {
                modes.renderFogLevel()
                fogPlaces.onCameraMove()
            }
            loadStyle()
        }
    }

    /**
     * Loads the served style and puts the live track and, once the session allows, the user
     * layers on it. "Try again" re-runs it after a failed load. MapLibre's attribution control
     * must stay enabled: it renders the ODbL credit the basemap requires.
     */
    private fun loadStyle() {
        val instance = map ?: return
        val v = views ?: return
        style = null
        overlaysAttached = false
        // The picked outline was the old style's; the new one starts with none.
        v.fogPlaces.close()
        // The layers document is fetched beside the style, so only the overlays wait for it.
        layersDoc = layersDoc?.takeIf { it.flavor == layers.flavor() } ?: MapLayersSource.last(requireContext(), layers.flavor())
        fetchLayers()
        instance.setStyle(Style.Builder().fromUri(layers.styleUrl())) { loaded ->
            style = loaded
            views?.notices?.hide(MapNotice.MAP_FAILED)
            layers.onStyleLoaded(loaded)
            MapOverlays.attachLiveTrack(loaded)
            syncSession()
            recording.render()
        }
    }

    /** Asks for the layers document again: at style load, and when the account's tile version
     *  moved ([CoverageController]). */
    private fun fetchLayers() {
        if (!Session.isSignedIn) return
        MapLayersSource.fetch(requireContext(), layers.flavor(), ::onLayers)
    }

    /**
     * A layers document arrived: applied in place of the one on the map, or kept for [syncSession]
     * to attach. One from another build than the style's means a deploy landed between the two
     * fetches, and the style is fetched again.
     */
    private fun onLayers(doc: MapLayersDoc.Doc) {
        if (map == null || doc.flavor != layers.flavor()) return
        layersDoc = doc
        val loaded = style ?: return
        if (doc.styleBuild != StyleMetadata.build(loaded)) {
            if (!styleReloaded) {
                styleReloaded = true
                loadStyle()
            }
            return
        }
        if (overlaysAttached) MapLayers.replace(loaded, doc) else syncSession()
    }

    /** A new intent to the host (`MainActivity.onNewIntent`): the notification's Stop, or the
     *  Sync screen's View on map. */
    fun onNewIntent(intent: Intent) {
        recording.handleIntent(intent)
        takeViewOnMap(intent)
    }

    /** The Sync screen's View on map ([viewOnMap]): kept until the session is confirmed
     *  (`syncSession`); the opening camera is skipped, since this track is the view. */
    private fun takeViewOnMap(intent: Intent) {
        // A relaunch from recents replays the intent; it has been handled.
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        val id = intent.getStringExtra(MainActivity.EXTRA_VIEW_TRACK) ?: return
        val day = intent.getStringExtra(MainActivity.EXTRA_VIEW_DAY) ?: return
        viewOnMapRequest = id to day
        views?.camera?.framed = true
    }

    /** Brings the map in line with the stored credential ([SessionGate]), on style load and on every resume. */
    private fun syncSession() {
        val v = views ?: return
        if (!v.gate.passes()) return
        TrackTypes.refresh()

        modeBarReady = true
        renderModeBar()
        if (daysStale) {
            daysStale = false
            v.area.reloadHistory()
            // Sync or a recording may have changed the area's tracks and an open Trip too.
            v.area.reloadList()
            v.panel.tripsTab.reloadOpen()
        }
        renderSheet()
        viewOnMapRequest?.let { (id, day) ->
            viewOnMapRequest = null
            viewTrackOnMap(id, day)
        }

        val loaded = style ?: return
        val doc = layersDoc?.takeIf { it.styleBuild == StyleMetadata.build(loaded) } ?: return
        if (!overlaysAttached) {
            MapOverlays.attach(loaded, doc, mode, session.dates, layers.satelliteDrawn(loaded), tripId)
            // The bike-path layers attach just added start hidden.
            layers.applyPaths(loaded)
            MapOverlays.setTrackFilter(loaded, panelState.mapHidden, panelState.highlighted)
            spots.attach(loaded, layers.shownSpots())
            overlaysAttached = true
            // The document's levels name Fog's button.
            v.modes.renderFogLevel()
            spots.onStyleAttached()
            bands.render()
            // A new style has none of the circles; draw them again if the editor has the map.
            v.edit.privacy.onStyleReady()
            // Nor the Sync tab's lines, which the account's tracks still step aside for.
            syncCandidates.draw()
            MapOverlays.setSyncing(loaded, v.panel.tab == PanelTab.SYNC, mode)
            if (isRecording()) MapOverlays.setRecording(loaded, true, mode)
            v.camera.open { v.area.followArea() }
            coverage.checkTileVersion()
        }
    }

    /** A Sync history row's View on map: Normal mode, the collapsed Tracks tab, and the
     *  track selected and flown to ([AreaController.viewTrack]). */
    private fun viewTrackOnMap(trackId: String, day: String) {
        val v = views ?: return
        pickMode(MapMode.NORMAL)
        // The expanded sheet would stay drawn over the very map the link is meant to show.
        v.panel.showTracks()
        v.area.viewTrack(trackId, day)
    }

    /** The toolbar's Edit ([EditController.open]). */
    private fun openEditWindow(group: List<Track>) {
        views?.edit?.open(group)
    }

    /** The Edit window opened or closed: the chrome steps aside for it or comes back. */
    private fun onEditWindowChanged(@Suppress("UNUSED_PARAMETER") open: Boolean) {
        val v = views ?: return
        v.chrome.placeEditors()
        renderSheet()
        renderBottomBar()
        v.sheetChrome.renderSelectionBar()
        renderModeBar()
        v.sheetChrome.renderRail()
        bands.render()
    }

    /** The Private location editor opened or closed. */
    private fun onPrivacyEditorChanged(open: Boolean) {
        val v = views ?: return
        if (open) v.chrome.placeEditors()
        v.sheetChrome.renderRail()
        renderSheet()
        renderBottomBar()
    }

    private fun renderBottomBar() {
        host?.setBottomBarShown(MapChromeRules.bottomBarShown(editOpen(), privacyEditing(), views?.export?.isOpen == true))
    }

    private fun onEditClosed(saved: Boolean, editedTrack: String?) {
        val area = views?.area ?: return
        editedTrack?.let(area.pending::awaitEdit)
        if (saved) area.reloadList()
    }

    /** Whether the Private location editor is open over the map. */
    private fun privacyEditing() = views?.edit?.privacyEditing == true

    /** The Private location editor has the map in Normal mode only: another mode or a recording
     *  closes it, unsaved draft and all. */
    private fun renderPrivacy() {
        val privacy = views?.edit?.privacy?.takeIf { it.isShowing } ?: return
        if (modeBarReady && !normalMode()) privacy.stop()
    }

    /** The Sync tab sent tracks; an empty map frames them once they're in. */
    private fun onSyncedFromPhone() {
        val v = views ?: return
        v.refresh.afterSync()
        if (v.notices.shown == MapNotice.EMPTY) v.camera.openAgain { v.area.followArea() }
    }

    private fun renderModeBar() {
        views?.modes?.render()
    }

    /** Applies the panel's hidden set, filters, Pending rows and selection to the track layers,
     *  the bands, the sheet's head and the selection bar. */
    private fun applyTrackFilter() {
        style?.takeIf { overlaysAttached }?.let { MapOverlays.setTrackFilter(it, panelState.mapHidden, panelState.highlighted) }
        bands.update(refetch = false)
        photos.refresh(force = false)
        renderSheet()
    }

    /**
     * A tap on the map in Normal mode: a track within [TAP_TOLERANCE_DP] (a 2.5dp line is too thin
     * to hit) is selected and flown to; empty map clears the selection. The sheet stays as it was.
     */
    private fun onMapTap(instance: MapLibreMap, point: LatLng): Boolean {
        val v = views ?: return false
        val edit = v.edit
        val editWindow = v.editWindow
        // Framing only pans and zooms (`docs/SPEC.md` FR-4.7).
        if (v.export.isOpen) return true
        // A spot's badge first, in every mode, unless an editor has the map; a tap elsewhere
        // closes its popup.
        if (!edit.privacy.isShowing && !editWindow.isOpen && spots.tap(instance, point)) {
            v.fogPlaces.close()
            return true
        }
        // The Sync tab's lines: one tapped is picked out on its list.
        if (v.panel.tab == PanelTab.SYNC && v.sheet.isVisible) {
            syncCandidates.keyAt(instance, point, resources.displayMetrics.density)?.let(v.panel.syncTab::focus)
            return true
        }
        // In Fog, the outline tapped is named; a tap off every outline closes it.
        if (mode == MapMode.FOG) {
            if (v.fogPlaces.tap(instance, point)) photos.closePopup()
            return true
        }
        if (!normalMode()) return false
        // The Private location editor has the map to itself while it's open.
        if (edit.privacy.isShowing) {
            edit.privacy.onMapTap(point)
            return true
        }
        // The Edit window's group mustn't change under it; a tap only serves Delete point.
        if (editWindow.isOpen) {
            if (editWindow.routeEditor.deleteMode) {
                RouteEditOverlay.pointAt(instance, point, resources.displayMetrics.density)?.let(editWindow.routeEditor::dropPoint)
            }
            return true
        }
        val screen = instance.projection.toScreenLocation(point)
        val tolerance = TAP_TOLERANCE_DP * resources.displayMetrics.density
        val box = RectF(screen.x - tolerance, screen.y - tolerance, screen.x + tolerance, screen.y + tolerance)
        val id = instance.queryRenderedFeatures(box, MapOverlays.TRACKS_LAYER_ID)
            .firstNotNullOfOrNull { it.getStringProperty("id") }
        if (id != null && panelState.tracks.any { it.id == id }) v.panel.trackTapped(id) else v.panel.clearFocus()
        return true
    }

    private fun renderSheet() {
        views?.sheetChrome?.render()
    }

    private fun isRecording() = recording.isRecording

    /** Normal mode, session ready, not recording: when the sheet and its editors have the map. */
    private fun normalMode() = MapChromeRules.normalMode(modeBarReady, mode, isRecording())

    /** The map follows the recording: while one runs the live track has the map, and the mode
     *  toggle, Find my location, the export and every history layer step aside. */
    private fun onRecordingChanged(active: Boolean, points: List<RecordedPoint>) {
        locate.setShown(!active)
        // Like every history layer, the photos give the map to the live track.
        photos.render()
        val v = views ?: return
        // The recording has the map: Fog's layers step aside, and its place popup with them.
        if (active) v.fogPlaces.close()
        renderModeBar()
        v.export.setAvailable(!active)
        renderSheet()
        v.notices.render()
        // The live line had the camera: the list asks about wherever it's left.
        if (!active) v.area.followArea(always = true)

        val loaded = style ?: return
        if (overlaysAttached) MapOverlays.setRecording(loaded, active, mode)
        MapOverlays.updateLiveTrack(loaded, points)
    }

    /** The user's, or the tour's, pick for the Tracks tab, shown there at once. */
    private fun pickMode(next: MapMode) {
        pickedMode = next
        applyTabMode()
    }

    /** The mode for the tab showing, and the toggle that's only the Tracks tab's. */
    private fun applyTabMode() {
        val shown = MapChromeRules.tabMode(pickedMode, tab)
        if (shown != mode) setMode(shown)
        renderModeBar()
    }

    private fun setMode(next: MapMode) {
        mode = next
        val v = views
        if (next != MapMode.FOG) v?.fogPlaces?.close()
        v?.modes?.check(next)
        style?.takeIf { overlaysAttached }?.let { MapOverlays.setMode(it, next) }
        v?.modes?.renderNotices()
        renderSheet()
        photos.refresh(force = false)
    }

    /**
     * Makes the export's hidden map (`export/MapImageRenderer`) look like this one, with the calls
     * [loadStyle] and [syncSession] make. No Spots or recording, as on the web; the viewfinder draws the photo markers onto the picture.
     */
    private fun prepareExportStyle(loaded: Style) {
        layers.applyPaths(loaded)
        layers.applyBasemap(loaded)
        val doc = layersDoc ?: return
        MapOverlays.attach(loaded, doc, mode, session.dates, layers.satelliteDrawn(loaded), tripId, EXPORT_EXCLUDED)
        layers.applyPaths(loaded)
        MapOverlays.setTrackFilter(loaded, panelState.mapHidden, panelState.highlighted)
        bands.drawn?.let { MapOverlays.setRouteBands(loaded, it) }
    }

    /** What [CameraFramer.open] found. An account with no geometry stays at the world view,
     *  with a notice pointing at Sync, re-checked on every resume until closed
     *  ([MapChromeRules.emptyNoticeShown]). */
    private fun onEmptyChecked(empty: Boolean) {
        // The answer can land after the activity was recreated, on a fragment no longer attached.
        if (!isAdded) return
        val notices = views?.notices ?: return
        host?.tour?.historyKnown(!empty)
        val dismissal = EmptyNoticeDismissal(requireContext(), Session.email)
        if (!MapChromeRules.emptyNoticeShown(empty, Session.isDemo, dismissal.closed())) {
            notices.hide(MapNotice.EMPTY)
            return
        }
        notices.show(
            MapNotice.EMPTY,
            getString(R.string.map_empty),
            action = R.string.nav_sync,
            onAction = { host?.showTab(MainActivity.Tab.SYNC) },
            onClose = dismissal::close,
        )
    }

    /** The style or its sources failed: a plain sentence, the origin and MapLibre's error in
     *  small print, and Try again. */
    private fun onBasemap(status: BasemapStatus) {
        val notices = views?.notices ?: return
        when (status) {
            BasemapStatus.UNREACHABLE -> notices.show(MapNotice.BASEMAP_UNREACHABLE, getString(R.string.map_basemap_unreachable), failed = true)
            BasemapStatus.LOADED -> notices.hide(MapNotice.BASEMAP_UNREACHABLE)
            BasemapStatus.LOADING -> Unit
        }
    }

    /** Satellite's imagery loads or fails on this device: the map's look follows, and its notice. */
    private fun onImagery(status: SatelliteStatus) {
        imageryStatus = status
        layers.onImagery(status)
        renderImageryNotice()
    }

    private fun onSatelliteSwitched() {
        views?.imagery?.onSwitched()
        renderImageryNotice()
    }

    private fun renderImageryNotice() {
        val notices = views?.notices ?: return
        if (layers.satelliteOn && imageryStatus == SatelliteStatus.FAILED) {
            notices.show(MapNotice.SATELLITE_FAILED, getString(R.string.map_satellite_failed), failed = true)
        } else {
            notices.hide(MapNotice.SATELLITE_FAILED)
        }
    }

    private fun reportFailure(error: String) {
        Log.e(TAG, "map failed to load: $error")
        views?.notices?.show(
            MapNotice.MAP_FAILED,
            getString(R.string.map_load_failed),
            detail = "${BuildConfig.API_BASE_URL} — $error",
            failed = true,
            action = R.string.retry,
        ) { loadStyle() }
    }

    // MapLibre's MapView holds a native renderer and a GL surface: every lifecycle callback below
    // is forwarded, since a missed one leaks the surface or crashes on rotation.
    override fun onStart() {
        super.onStart()
        val v = views
        v?.mapView?.onStart()
        v?.basemap?.start()
        v?.imagery?.start()
        SyncProgress.addListener(syncProgressListener)
        SyncProgress.resume(requireContext())
        v?.area?.pending?.start()
        coverage.resume()
        recording.start()
    }

    override fun onResume() {
        super.onResume()
        daysStale = true
        val v = views
        v?.mapView?.onResume()
        syncSession()
        if (overlaysAttached) {
            spots.loadCaptures(onlyNew = true)
            // Back from elsewhere (the web, Sync): new tiles if the version moved, and the notice
            // if the account's coverage is still being worked on.
            coverage.checkTileVersion()
        }
        spots.resume()
        v ?: return
        // An empty map is checked again on every return, so the notice goes and the camera frames
        // the history once something arrives.
        if (v.notices.shown == MapNotice.EMPTY) v.camera.openAgain { v.area.followArea() }
        // Back from Health Connect's settings or a recording's Edit: the Sync tab reads again.
        if (!isHidden) v.panel.syncTab.resume()
    }

    /** The You tab over the map, or the map back: the Sync tab stops reading, or reads again. */
    override fun onHiddenChanged(hidden: Boolean) {
        super.onHiddenChanged(hidden)
        val v = views ?: return
        if (hidden) v.export.close()
        if (hidden) v.panel.syncTab.pause() else v.panel.syncTab.resume()
    }

    override fun onPause() {
        spots.pause()
        views?.mapView?.onPause()
        super.onPause()
    }

    override fun onStop() {
        val v = views
        // Health Connect's routes can't be read in the background (`docs/IMPLEMENTATION.md` §4.0).
        v?.panel?.syncTab?.pause()
        v?.area?.pending?.stop()
        coverage.stop()
        SyncProgress.removeListener(syncProgressListener)
        recording.stop()
        v?.basemap?.stop()
        v?.imagery?.stop()
        v?.mapView?.onStop()
        super.onStop()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString(STATE_MODE, pickedMode.name)
        AreaController.save(outState, session.dates)
        val v = views ?: return
        v.mapView.onSaveInstanceState(outState)
        // The camera MapLibre just saved is where the user left it, once it's been framed.
        outState.putBoolean(STATE_FRAMED, v.camera.framed)
        v.chrome.save(outState)
    }

    override fun onLowMemory() {
        super.onLowMemory()
        views?.mapView?.onLowMemory()
    }

    override fun onDestroyView() {
        val v = views
        v?.export?.close()
        recording.dismissDialogs()
        layers.dismiss()
        v?.modes?.dismissFogLevel()
        spots.stopCapture()
        v?.mapView?.onDestroy()
        // A fetch that lands after this must find no map: the destroyed style throws on every call.
        map = null
        style = null
        overlaysAttached = false
        v?.area?.release()
        coverage.stop()
        views = null
        super.onDestroyView()
    }

    companion object {
        private const val TAG = "HoldMyTrack"

        /** How far from a tap a track still counts as tapped, as on the web. */
        private const val TAP_TOLERANCE_DP = 14

        private const val STATE_MODE = "mode"
        private const val STATE_FRAMED = "framed"

        /** What the export leaves out, as on the web: the places. */
        private val EXPORT_EXCLUDED = setOf("spots")
    }
}
