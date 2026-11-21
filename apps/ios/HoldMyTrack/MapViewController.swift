import CoreLocation
import HoldMyTrackCore
import MapLibre
import UIKit

/// The map (apps/android/docs/SPEC.md FR-2.1–FR-2.7): the basemap style and the account's layers
/// document combined into one style (MapStyle), Normal and Fog of War, the Layers menu,
/// the first framing, Find my location, the notices for an unreachable basemap, coverage still
/// updating and an empty account, and the sheet with the Tracks and Trips tabs, shared by
/// the Tracks and Trips tabs of the tab bar (MapHostViewController). The date range is
/// MapViewController+Range, the sheet's wiring MapViewController+Panel.
final class MapViewController: UIViewController, @preconcurrency MLNMapViewDelegate, @preconcurrency CLLocationManagerDelegate {
    unowned let flow: AppFlow
    /// Read again when a site page closes (AppFlow.accountChanged): Settings can change the units.
    private(set) var account: Account
    private let documents: MapDocuments
    /// Made in viewDidLoad at the view's size: started at a zero frame, MapLibre keeps drawing
    /// into a quarter of the screen after it grows.
    var mapView: MLNMapView!
    let modes = ModeToggle()
    /// While recording, its status in the toggle's place (MapViewController+TopRow).
    let recordingCard = RecordingCard()
    /// The export under the selection bar while rows are checked and the rail is away.
    lazy var checkedExport = RailItem(UIButton(type: .system), icon: UIImage(resource: .camera),
                                      label: String(localized: "export.open", defaultValue: "Export map image", comment: "The map's camera button: open the image export."),
                                      id: "checkedExport")
    /// Whether the tab bar and the record button show (MapChrome.bottomBarShown).
    var onBottomBar: ((Bool) -> Void)?
    /// The recording status's Stop: the tab bar asks first.
    var onStopAsked: (() -> Void)?
    let layersButton = UIButton(type: .system)
    let placesButton = UIButton(type: .system)
    /// Satellite's watch (MapViewController+Chrome).
    lazy var chrome = MapChromeViews { [weak self] in self?.onImagery($0) }
    let locateButton = UIButton(type: .system)
    /// Layers, Places, Find my location and the export down the right edge (MapViewController+Rail).
    lazy var rail = MapRail(layers: layersButton, places: placesButton, locate: locateButton, export: export.button)
    /// Layers waits for the layers document, which gives it Satellite and the swatches.
    lazy var layersMenu = MapMenuPopup(host: view, anchor: rail.layers, canOpen: { [unowned self] in self.pair != nil }) { [unowned self] in self.layersContent() }
    lazy var placesMenu = MapMenuPopup(host: view, anchor: rail.places) { [unowned self] in self.placesContent() }
    /// Fog's level menu, under the toggle and lined up with its start, once the document has levels.
    lazy var fogLevelMenu = MapMenuPopup(host: view, anchor: modes, alignStart: true, canOpen: { [unowned self] in
        self.state.mode == .fog && !self.levels.isEmpty && !self.modes.isHidden
    }) { [unowned self] in self.fogLevelContent() }
    /// The controls along the top: the mode toggle and the rail, then the notices under them.
    let chromeColumn = PassThroughStackView()
    /// The toggle beside the rail.
    let topRow = PassThroughStackView()
    /// Under the top row, the camera while rows are checked.
    let underBar = PassThroughStackView()
    let notices = MapNotices()
    private let location = CLLocationManager()
    let modesRow = PassThroughStackView()
    /// Takes the row's room while the toggle is hidden, so the rail keeps its place.
    let modesSpacer = UIView()

    var session = MapSession()

    // The area list and Dates (MapViewController+Area).
    /// The first and newest tracks' days, Dates' bounds.
    var history: (earliest: String?, latest: String?) = (nil, nil)
    /// How many tracks the last area held, more than listed past the cap; nil for a Trip.
    var areaTotal: Int?
    /// Whether the map was too far out to list anything at the last load.
    var zoomedOut = false
    /// The app is moving the camera itself, which the list doesn't follow.
    var appFlying = false
    var settleTask: Task<Void, Never>?
    weak var datesSheet: DatesViewController?

    // The sheet (MapViewController+Panel).
    let sheet = PanelSheetView()
    var tracksPanel: TracksPanel!
    var tripsPanel: TripsPanel!
    /// The Sync tab's sheet, handed in by the tab bar, which owns the recordings it lists.
    var syncPanel: SyncPanel?
    var panelTab = PanelTab.tracks
    /// The list for the range or the open Trip, as the server last sent it.
    var tracks: [Track] = []
    var listLoading = false
    var listError: String?
    var listTask: Task<Void, Never>?
    /// The ids held Pending, and edits saved here not yet seen done (PendingDiff).
    var pendingIDs: Set<String> = []
    var awaiting: Set<String> = []
    var pendingTask: Task<Void, Never>?
    /// Bumped whenever tracks change under the same query, so their tiles are fetched again.
    var tracksVersion = 0
    var editOpen = false {
        didSet {
            renderTopRow()
            if oldValue && !tourBlocked { onMapFreed?() }
        }
    }
    /// The focused track's pace bands (MapViewController+Bands).
    var bands = BandsState()
    /// Points of interest (MapViewController+Spots).
    var spots = SpotsState(categories: MapPreferences.spots())
    let spotViews = SpotViews()
    /// Fog's level menu and place popup (MapViewController+Fog).
    let fogViews = FogViews()
    /// The map image export (MapViewController+Export).
    let export = ExportState()
    /// The Private location editor (MapViewController+PrivateLocations).
    let privateLocations = PrivateLocationsState()
    /// Photos on the map (MapViewController+Photos).
    var photos = PhotosState()
    /// The Edit window while it's open, and the track it edits (MapViewController+RouteEdit).
    weak var editWindow: EditTrackViewController?
    var routeEdit = RouteEditState()
    lazy var photoViews = PhotoViews(api: flow.api, format: { [unowned self] in self.format }, onOpen: { [weak self] in self?.openPhotos($0) })
    /// Capture of a place (CaptureController), which lives no longer than the map.
    lazy var capturing = CaptureController(api: flow.api, map: captureMap(), format: { [unowned self] in self.format })
    /// View on map's track, focused when the next list holds it.
    var focusWhenListed: String?
    /// The tab bar's Trips count: copies others sent, waiting.
    var onWaiting: ((Int) -> Void)?
    /// A row's Trip badge on the Tracks tab: the tab bar moves to Trips.
    var onWantsTrips: ((String) -> Void)?
    /// The empty map's Sync: the bottom bar's Sync tab.
    var onWantsSync: (() -> Void)?
    /// The user picked a mode on the toggle, which may earn Fog's first-time card (TourController).
    var onModePicked: ((MapMode) -> Void)?
    /// The first framing found whether the account has any track: the tour starts or is offered.
    var onHistoryKnown: ((Bool) -> Void)?
    /// The Edit window or the Private location editor gave the map back (tourBlocked).
    var onMapFreed: (() -> Void)?
    /// Whether each account (AccountKey) has any track, as its first framing found, for a later
    /// signed-in screen in the same app session, which doesn't frame again.
    static var hasTracks: [String: Bool] = [:]
    /// A recording runs: the map shows only it (MapViewController+Recording).
    var recordingLive = false
    /// Whether the camera has flown to this recording's first fix; later fixes only pan.
    var recordingFollowed = false
    var lastRecordingPoints: [RecordedPoint] = []
    var recordingNoticeShown = 0
    /// Counts the tour's camera moves, so a move's end only continues the latest (MapViewController+Tour).
    var tourMoves = 0

    var state = MapState()
    var pair: MapDocuments.Pair?
    /// The style last handed to MapLibre, which the next one is compared with.
    private var loaded: JSONValue?
    private var styleLoaded = false
    private var basemapLoaded = false
    private var basemapFailed = false
    private var basemapClock: Date?
    private var coverageTask: Task<Void, Never>?
    /// Find my location was tapped and waits on the prompt or the first position.
    private var locating = false

    /// The first framing happens once per app session, not on every return to the map.
    static var framed: Set<String> = []

    var format: PanelFormat { PanelFormat(account: account) }

    private var flavor: String { traitCollection.userInterfaceStyle == .dark ? "dark" : "light" }
    var accountKey: String { AccountKey.of(email: account.email, isDemo: account.isDemo) }

    init(flow: AppFlow, account: Account) {
        self.flow = flow
        self.account = account
        self.documents = MapDocuments(api: flow.api, account: AccountKey.of(email: account.email, isDemo: account.isDemo))
        super.init(nibName: nil, bundle: nil)
        MapPreferences.restore(into: &state)
        Spots.apply(categories: spots.categories, captured: [:], target: nil, to: &state)
        pickedMode = state.mode
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .bg)
        mapView = MLNMapView(frame: view.bounds)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.delegate = self
        mapView.styleJSON = Self.emptyStyle
        mapView.setCenter(CLLocationCoordinate2D(latitude: 20, longitude: 0), zoomLevel: 1, animated: false)
        // MapLibre's mark and its credit at the bottom start, as on Android (placeAttribution).
        mapView.logoViewPosition = .bottomLeft
        mapView.attributionButtonPosition = .bottomLeft
        mapView.accessibilityIdentifier = "map"
        view.addSubview(mapView)
        layoutChrome()
        buildPanel()
        NotificationCenter.default.addObserver(forName: AppFlow.accountChanged, object: nil, queue: .main) { [weak self] note in
            let changed = note.userInfo?["account"] as? Account
            MainActor.assumeIsolated {
                guard let self, let account = changed else { return }
                self.account = account
                self.renderPanel()
            }
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.load()
            self.exportLookChanged()
        }
        location.delegate = self
        load()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        checkCoverage()
        countSatelliteWait(onScreen: true)
        loadCaptures()
        openOnce()
        loadHistory()
        loadList()
        if panelTab != .trips { tripsPanel.refreshCount() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let guide = view.safeAreaLayoutGuide.layoutFrame
        sheet.setRoom(container: guide.height, topInset: chromeBottom - guide.minY)
        layersMenu.place()
        placesMenu.place()
        fogLevelMenu.place()
        placeAttribution()
        layoutExport()
    }

    /// The rail turns before the layout that measures it for the sheet.
    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        rail.layOut(landscape: size.width > size.height)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        coverageTask?.cancel()
        countSatelliteWait(onScreen: false)
        // Leaving the map ends a capture and drops the Private location editor's draft: iOS has
        // no Back, and the Tracks tab is where they show.
        capturing.stop()
        closePrivateEditor()
        closeExport()
        dismissMenus()
    }

    // MARK: The documents

    /// The kept pair at once, then the server's: a theme or language change, or a new tile
    /// version, comes through here.
    private func load() {
        let flavor = flavor, language = AppLanguage.current
        if let kept = documents.kept(flavor: flavor, language: language) { show(kept) }
        Task {
            do {
                show(try await documents.fetch(flavor: flavor, language: language))
            } catch let error as APIError {
                if pair == nil, error != .outdated { mapFailed(Self.describe(MapChrome.loadFailure(error))) }
            } catch {}
        }
    }

    /// The documents or the style didn't load: where the app asked and what came back, in small
    /// print, and Try again (Android's reportFailure).
    private func mapFailed(_ what: String) {
        notice(.mapFailed, String(localized: "The map couldn't load."), detail: "\(flow.api.app.apiBaseURL.absoluteString) — \(what)",
               action: (String(localized: "Try again"), { [weak self] in
                   self?.hideNotice(.mapFailed)
                   self?.load()
               }))
    }

    private static func describe(_ failure: MapChrome.LoadFailure) -> String {
        switch failure {
        case .status(let status, let message): message.map { "\(status) \($0)" } ?? "HTTP \(status)"
        case .noAnswer: String(localized: "no answer", comment: "Map: the small print when the server didn't answer.")
        case .unreadable: String(localized: "an answer the app can't read", comment: "Map: the small print when the server's answer couldn't be read.")
        }
    }

    private func show(_ pair: MapDocuments.Pair) {
        self.pair = pair
        hideNotice(.mapFailed)
        render()
        if styleLoaded, let style = mapView.style { addBadgeImages(to: style) }
        updateRailMenus()
        renderInArea()
        countSatelliteWait(onScreen: viewIfLoaded?.window != nil)
        renderLevel()
    }

    /// The style for the current state: patched in place when only properties changed, else
    /// reloaded, which keeps the camera.
    func render() {
        guard let pair else { return }
        let next = MapStyle.compose(style: pair.style, document: SyncLines.adding(to: pair.layers), state: state, apiBase: flow.api.app.apiBaseURL)
        if let loaded, styleLoaded, let style = mapView.style, let changes = MapStyle.changes(from: loaded, to: next),
           MapPatcher.apply(changes, to: style) {
            self.loaded = next
            return
        }
        guard next != loaded, let json = String(data: next.data, encoding: .utf8) else { return }
        loaded = next
        styleLoaded = false
        startBasemapClock()
        mapView.styleJSON = json
    }

    func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
        renderLevel()
        spots.area.cameraMoved()
        renderInArea()
        placeSpotPopup()
        placeFogPlace()
        regroupPhotos()
        cameraSettled()
    }

    func mapViewRegionIsChanging(_ mapView: MLNMapView) {
        renderLevel()
        placeSpotPopup()
        placeFogPlace()
        placePhotos()
        capturing.mapRotated()
    }

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
        styleLoaded = true
        addBadgeImages(to: style)
        addGuide(to: style)
        addRouteEdit(to: style)
        addRecording(to: style)
        addPrivateLocations(to: style)
    }

    /// How far down the controls over the map reach, the camera under the selection bar included:
    /// the sheet stops under them, and a popup goes under its place above it.
    var chromeBottom: CGFloat {
        let lowest = underBar.isHidden ? topRow : underBar
        return lowest.convert(lowest.bounds, to: view).maxY + DesignTokens.Space.s8
    }

    /// The tracks' lines a tap is asked about (TrackTap).
    var trackLayers: Set<String> { pair.map { TrackTap.layerIDs($0.layers) } ?? [] }

    // MARK: Modes and the Layers menu

    /// The mode picked on the Tracks tab, which state.mode shows there and comes back to after
    /// Trips (TabMode).
    var pickedMode = MapMode.normal

    /// The user's pick, shown at once on the Tracks tab.
    func pickMode(_ mode: MapMode) {
        pickedMode = mode
        MapPreferences.save(state, mode: pickedMode)
        applyTabMode()
    }

    /// The mode for the tab showing, and the toggle, which is only the Tracks tab's.
    func applyTabMode() {
        let onTracks = panelTab == .tracks
        // The editor is the Tracks tab's, in Normal.
        if !onTracks || pickedMode != .normal { closePrivateEditor() }
        let shown = TabMode.shown(picked: pickedMode, onTracksTab: onTracks, recording: recordingLive)
        modes.select(pickedMode)
        renderTopRow()
        renderLevel()
        // The account's tracks step aside for a recording and for the Sync tab's own lines.
        let hidden = TabMode.hiddenGroups(recording: recordingLive, syncing: panelTab == .sync)
        let asideChanged = hidden != state.hiddenGroups
        state.hiddenGroups = hidden
        guard shown != state.mode else {
            if asideChanged { render() }
            return
        }
        state.mode = shown
        renderLevel()
        render()
        checkCoverage()
        renderPanel()
        refreshPhotos(force: false)
    }

    // MARK: Framing


    /// The camera on box, clear of the controls over the map, at most maxZoom.
    func fit(_ box: [Double], animated: Bool, maxZoom: Double = MapFraming.maxZoom, completion: (() -> Void)? = nil) {
        let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: box[1], longitude: box[0]),
                                         ne: CLLocationCoordinate2D(latitude: box[3], longitude: box[2]))
        let bottom = (sheet.isHidden ? 0 : sheet.restingHeight) + 48
        let padding = UIEdgeInsets(top: 120, left: 48, bottom: bottom, right: 48)
        // One move, so the list knows when the app's flight is over (cameraSettled): a box that
        // would zoom in past maxZoom is widened about its centre to what maxZoom shows instead.
        let camera = mapView.cameraThatFitsCoordinateBounds(bounds, edgePadding: padding)
        let zoom = MLNZoomLevelForAltitude(camera.altitude, camera.pitch, camera.centerCoordinate.latitude, mapView.bounds.size)
        var target = bounds
        if zoom > maxZoom {
            let grow = pow(2, zoom - maxZoom)
            let lat = (box[1] + box[3]) / 2, lon = (box[0] + box[2]) / 2
            let halfLat = (box[3] - box[1]) / 2 * grow, halfLon = (box[2] - box[0]) / 2 * grow
            target = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: lat - halfLat, longitude: lon - halfLon),
                                         ne: CLLocationCoordinate2D(latitude: lat + halfLat, longitude: lon + halfLon))
        }
        appFlying = true
        mapView.setVisibleCoordinateBounds(target, edgePadding: padding, animated: animated) { [weak self] in
            DispatchQueue.main.async {
                self?.appFlying = false
                completion?()
            }
        }
    }

    // MARK: Find my location

    private func locate() {
        switch location.authorizationStatus {
        case .notDetermined:
            locating = true
            location.requestWhenInUseAuthorization()
        case .denied, .restricted: notice(.location, String(localized: "HoldMyTrack needs location access to show where you are. Turn it on in Settings."))
        default: followUser()
        }
    }

    /// iOS also calls this when the delegate is set, at every launch: only a tap's prompt follows.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            hideNotice(.location)
            if locating { followUser() }
        case .denied, .restricted: locating = false
        default: break
        }
    }

    /// Flies to at least zoom 14 and follows the position until the map is panned. Before the
    /// first position the camera waits for it (didUpdate): following with none loses the zoom.
    private func followUser() {
        mapView.showsUserLocation = true
        guard mapView.userLocation?.location != nil else {
            locating = true
            return
        }
        locating = false
        // Following sets its own zoom as it starts; zooming after keeps following.
        mapView.setUserTrackingMode(.follow, animated: true) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.mapView.zoomLevel < 14 else { return }
                self.mapView.setZoomLevel(14, animated: true)
            }
        }
    }

    func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
        if locating, location.authorizationStatus != .notDetermined, userLocation?.location != nil { followUser() }
    }

    // MARK: Coverage still updating

    /// Fog says when coverage is still being redrawn, checked on every opening of the map, and
    /// refreshes when the server is done (root docs/SPEC.md FR-4.2).
    func checkCoverage() {
        coverageTask?.cancel()
        guard state.mode != .normal else {
            hideNotice(.coverage)
            return
        }
        coverageTask = Task {
            var wasRendering = false
            while !Task.isCancelled {
                guard let status = try? await flow.api.coverageStatus() else { return }
                if let explored = status.explored { fogViews.explored = explored }
                if status.rendering {
                    wasRendering = true
                    notice(.coverage, String(localized: "Your map is still being updated, so Fog may be incomplete for now. It'll refresh on its own."))
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                hideNotice(.coverage)
                if wasRendering || status.tileVersion != pair?.layers.tileVersion { load() }
                return
            }
        }
    }

    // MARK: The basemap's reachability

    private func startBasemapClock() {
        basemapLoaded = false
        basemapFailed = false
        basemapClock = Date()
        hideNotice(.basemap)
        Task {
            try? await Task.sleep(for: .milliseconds(BasemapStatus.waitMs + 100))
            updateBasemapNotice()
        }
    }

    private func updateBasemapNotice() {
        let waited = basemapClock.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        switch BasemapStatus.of(loaded: basemapLoaded, failed: basemapFailed, waitedMs: waited) {
        case .unreachable: notice(.basemap, String(localized: "The map can't reach its tile server. Your network may be blocking it."))
        case .loaded, .loading: hideNotice(.basemap)
        }
    }

    /// The style's basemap source, whose tiles alone say whether the basemap is reachable: the
    /// map as a whole never finishes rendering while another source's tiles fail.
    private static let basemapSource = "protomaps"

    /// Called off the main thread for every tile of every source: the basemap's and the
    /// imagery's arrivals and failures.
    nonisolated func mapView(_ mapView: MLNMapView, tileDidTriggerAction operation: MLNTileOperation, x: Int, y: Int, z: Int,
                             wrap: Int, overscaledZ: Int, sourceID: String) {
        guard sourceID == Self.basemapSource || sourceID == MapStyle.satelliteID else { return }
        let loaded: Bool
        switch operation {
        case .loadFromNetwork, .loadFromCache: loaded = true
        case .error: loaded = false
        default: return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if sourceID == MapStyle.satelliteID {
                self.chrome.satellite.tile(loaded: loaded)
            } else if loaded ? !self.basemapLoaded : !self.basemapFailed {
                if loaded { self.basemapLoaded = true } else { self.basemapFailed = true }
                self.updateBasemapNotice()
            }
        }
    }

    func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
        mapFailed(error.localizedDescription)
    }

    // MARK: Notices

    enum Notice: Int { case mapFailed, basemap, satellite, coverage, empty, location, capped, tour, exported, recording }

    /// Shows kind's notice under the top row, or changes its words (MapNotices.show).
    func notice(_ kind: Notice, _ text: String, detail: String? = nil, action: (title: String, run: () -> Void)? = nil, onClose: (() -> Void)? = nil) {
        notices.show(kind.rawValue, text, detail: detail, actions: action.map { [MapNotices.Action(title: $0.title, id: "noticeAction", run: $0.run)] } ?? [], onClose: onClose)
    }

    /// Whether kind's notice is up.
    func noticeShown(_ kind: Notice) -> Bool { notices.shown(kind.rawValue) }

    func hideNotice(_ kind: Notice) {
        notices.hide(kind.rawValue)
    }

    // MARK: Layout

    /// The base map's credit, where MapChrome.credit puts it.
    private func placeAttribution() {
        let place = MapChrome.credit(sheetShown: !sheet.isHidden, collapsedSheet: Double(sheet.collapsedHeight), logoWidth: Double(mapView.logoView.bounds.width), gap: Double(DesignTokens.Space.s8), space: Double(DesignTokens.Space.s4))
        mapView.logoViewMargins = CGPoint(x: place.logoX, y: place.lift)
        mapView.attributionButtonMargins = CGPoint(x: place.buttonX, y: place.lift)
    }

    private func layoutChrome() {
        // A tap on Fog while it's on opens its level menu and changes nothing else, so Fog's
        // first-time card, which says to pick a level, stays up.
        modes.onPick = { [weak self] mode in
            guard let self else { return }
            if MapChrome.fogMenuOnTap(tapped: mode, current: self.state.mode) { return self.fogLevelMenu.toggle() }
            self.pickMode(mode)
            self.onModePicked?(mode)
        }
        modes.select(state.mode)
        modes.setContentHuggingPriority(.required, for: .horizontal)
        // At a large text size the toggle gives way, so the rail keeps its place.
        modes.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        recordingCard.onStop = { [weak self] in self?.onStopAsked?() }
        checkedExport.button.addAction(UIAction { [weak self] _ in self?.openExport() }, for: .primaryActionTriggered)

        locateButton.addAction(UIAction { [weak self] _ in self?.locate() }, for: .primaryActionTriggered)
        layersButton.addAction(UIAction { [weak self] _ in self?.layersMenu.open() }, for: .primaryActionTriggered)
        placesButton.addAction(UIAction { [weak self] _ in self?.placesMenu.open() }, for: .primaryActionTriggered)
        updateRailMenus()

        modesSpacer.isHidden = true
        modesSpacer.isUserInteractionEnabled = false
        // The selection bar joins them with the panel (buildPanel).
        for v in [modes, recordingCard, modesSpacer] { modesRow.addArrangedSubview(v) }
        modesRow.alignment = .center
        let inArea = PassThroughStackView(arrangedSubviews: [spotViews.inArea])
        inArea.axis = .vertical
        inArea.alignment = .center
        spotViews.inArea.addAction(UIAction { [weak self] _ in self?.loadInArea() }, for: .primaryActionTriggered)
        spotViews.popup.onCapture = { [weak self] spot in
            self?.closeFogPlace()
            self?.capturing.start(spot)
        }
        // The toggle and Show in this area at the start, the rail at the end; the notices under both.
        let start = PassThroughStackView(arrangedSubviews: [modesRow, inArea])
        start.axis = .vertical
        start.spacing = DesignTokens.Space.s8
        rail.layOut(landscape: view.bounds.width > view.bounds.height)
        // The start takes the row's room; the rail keeps to its buttons.
        for v in [start, rail.view] { topRow.addArrangedSubview(v) }
        topRow.spacing = DesignTokens.Space.s8
        topRow.alignment = .top
        let gap = UIView()
        gap.isUserInteractionEnabled = false
        for v in [gap, checkedExport] { underBar.addArrangedSubview(v) }
        underBar.isHidden = true
        for v in [topRow, underBar, capturing.banner, notices] { chromeColumn.addArrangedSubview(v) }
        chromeColumn.axis = .vertical
        chromeColumn.spacing = DesignTokens.Space.s8
        let column = chromeColumn

        // Over the map and under its controls: the photo markers, then the popups.
        photoViews.markers.frame = view.bounds
        photoViews.markers.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(photoViews.markers, aboveSubview: mapView)
        view.insertSubview(spotViews.popup, aboveSubview: photoViews.markers)
        bindPhotos()
        for v in [column, sheet] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        setUpFogControl()
        setUpExport()
        renderTopRow()
        bindPrivateEditor()
        // Over the sheet: opened low on the map, the photo popup runs past the sheet's edge.
        view.addSubview(photoViews.popup)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: guide.topAnchor, constant: DesignTokens.Space.s8),
            column.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: DesignTokens.Space.s12),
            column.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -DesignTokens.Space.s12),
            sheet.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            sheet.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            sheet.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
        ])
    }

    /// What the map shows before the documents arrive: the background alone.
    static let emptyStyle = ##"{"version":8,"sources":{},"layers":[{"id":"background","type":"background","paint":{"background-color":"#e8e4da"}}]}"##
}

/// Whether this phone closed the empty map notice for an account (AccountKey), which then stays
/// down for it.
@MainActor
enum EmptyNoticeDismissal {
    private static let defaults = UserDefaults.standard

    private static func key(_ account: String) -> String { "map.emptyNoticeClosed.\(account)" }

    static func closed(account: String) -> Bool { defaults.bool(forKey: key(account)) }

    static func close(account: String) { defaults.set(true, forKey: key(account)) }

    static func forget(account: String) { defaults.removeObject(forKey: key(account)) }
}

/// The Layers menu, kept on the phone rather than the account (apps/android/docs/SPEC.md FR-2.2):
/// all off but Roads and Show layers until changed. The mode lasts the app session, through a
/// theme or language change.
@MainActor
enum MapPreferences {
    private static let defaults = UserDefaults.standard
    private static var mode = MapMode.normal
    /// The Fog level locked, for the app session.
    private static var fogLevel: String?

    static func restore(into state: inout MapState) {
        state.mode = mode
        state.fogLevel = fogLevel
        state.satellite = defaults.bool(forKey: "map.satellite")
        state.roads = defaults.object(forKey: "map.roads") as? Bool ?? true
        state.showLayers = defaults.object(forKey: "map.showLayers") as? Bool ?? true
        state.showPlaces = defaults.object(forKey: "map.showPlaces") as? Bool ?? true
        state.toggles = defaults.dictionary(forKey: "map.toggles") as? [String: Bool] ?? [:]
    }

    /// mode is the Tracks tab's pick, which the map may not be showing on another tab.
    static func save(_ state: MapState, mode picked: MapMode) {
        mode = picked
        fogLevel = state.fogLevel
        defaults.set(state.satellite, forKey: "map.satellite")
        defaults.set(state.roads, forKey: "map.roads")
        defaults.set(state.showLayers, forKey: "map.showLayers")
        defaults.set(state.showPlaces, forKey: "map.showPlaces")
        defaults.set(state.toggles.filter { $0.key != Spots.group }, forKey: "map.toggles")
    }

    /// The places picked, every one off until ticked.
    static func spots() -> [SpotCategory] {
        let saved = Set(defaults.stringArray(forKey: "map.spots") ?? [])
        return SpotCategory.allCases.filter { saved.contains($0.rawValue) }
    }

    static func saveSpots(_ categories: [SpotCategory]) {
        defaults.set(categories.map(\.rawValue), forKey: "map.spots")
    }
}
