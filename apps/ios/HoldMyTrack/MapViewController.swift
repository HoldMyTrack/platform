import CoreLocation
import HoldMyTrackCore
import MapLibre
import UIKit

/// The map (apps/android/docs/SPEC.md FR-2.1–FR-2.7): the basemap style and the account's layers
/// document combined into one style (MapStyle), Normal, Fog of War and Heatmap, the Layers menu,
/// the first framing, Find my location, the notices for an unreachable basemap, coverage still
/// updating and an empty account, and the sheet with the Activities and Stories tabs, shared by
/// the Map and Stories tabs of the tab bar (MapHostViewController). The date range is
/// MapViewController+Range, the sheet's wiring MapViewController+Panel.
final class MapViewController: UIViewController, @preconcurrency MLNMapViewDelegate, @preconcurrency CLLocationManagerDelegate {
    unowned let flow: AppFlow
    /// Read again when a site page closes (AppFlow.accountChanged): Settings can change the units.
    private(set) var account: Account
    private let documents: MapDocuments
    /// Made in viewDidLoad at the view's size: started at a zero frame, MapLibre keeps drawing
    /// into a quarter of the screen after it grows.
    var mapView: MLNMapView!
    let modes = UISegmentedControl()
    private let layersButton = UIButton(type: .system)
    private let locateButton = UIButton(type: .system)
    private let notices = Controls.column([], spacing: DesignTokens.Space.s8)
    private let location = CLLocationManager()
    let slider = DateRangeSlider()
    private let modesRow = UIStackView()

    var session = MapSession()
    var days = ActivityDays(windowDays: DateRangeSlider.initialWindowDays)
    /// One earlier page at a time: a second would prepend the same page twice.
    var loadingEarlier = false

    // The sheet (MapViewController+Panel).
    let sheet = PanelSheetView()
    var activitiesPanel: ActivitiesPanel!
    var storiesPanel: StoriesPanel!
    var panelTab = PanelTab.activities
    /// The list for the range or the open Story, as the server last sent it.
    var activities: [Activity] = []
    var listLoading = false
    var listError: String?
    var listTask: Task<Void, Never>?
    /// The ids Pending in the last list, and edits saved here not yet seen done (PendingDiff).
    var pendingIDs: Set<String> = []
    var awaiting: Set<String> = []
    var pendingTask: Task<Void, Never>?
    /// Bumped whenever tracks change under the same query, so their tiles are fetched again.
    var tracksVersion = 0
    var editOpen = false
    /// View on map's activity, focused when the next list holds it.
    var focusWhenListed: String?
    /// The tab bar's Stories count: copies others sent, waiting.
    var onWaiting: ((Int) -> Void)?
    /// A row's Story badge on the Activities tab: the tab bar moves to Stories.
    var onWantsStories: ((String) -> Void)?

    var state = MapState()
    var pair: MapDocuments.Pair?
    /// The style last handed to MapLibre, which the next one is compared with.
    private var loaded: JSONValue?
    private var styleLoaded = false
    private var basemapLoaded = false
    private var basemapFailed = false
    private var basemapClock: Date?
    private var coverageTask: Task<Void, Never>?

    /// The first framing happens once per app session, not on every return to the map.
    private static var framed: Set<String> = []

    var format: PanelFormat { PanelFormat(account: account) }

    private var flavor: String { traitCollection.userInterfaceStyle == .dark ? "dark" : "light" }
    private var accountKey: String { AccountKey.of(email: account.email, isDemo: account.isDemo) }

    init(flow: AppFlow, account: Account) {
        self.flow = flow
        self.account = account
        self.documents = MapDocuments(api: flow.api, account: AccountKey.of(email: account.email, isDemo: account.isDemo))
        super.init(nibName: nil, bundle: nil)
        state.excludedGroups = ["spots"] // drawn with the panel's work (ROADMAP.md, 7b.3)
        MapPreferences.restore(into: &state)
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
        mapView.logoView.isHidden = true
        mapView.attributionButton.isHidden = false
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
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.load() }
        location.delegate = self
        load()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        checkCoverage()
        frameOnce()
        reloadDays()
        loadList()
        if panelTab != .stories { storiesPanel.refreshCount() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let guide = view.safeAreaLayoutGuide.layoutFrame
        sheet.setRoom(container: guide.height, topInset: modesRow.frame.maxY - guide.minY + DesignTokens.Space.s8)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        coverageTask?.cancel()
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
                if pair == nil, error != .outdated { notice(.mapFailed, String(localized: "The map couldn't load.")) }
            } catch {}
        }
    }

    private func show(_ pair: MapDocuments.Pair) {
        self.pair = pair
        render()
        updateLayersMenu()
    }

    /// The style for the current state: patched in place when only properties changed, else
    /// reloaded, which keeps the camera.
    func render() {
        guard let pair else { return }
        let next = MapStyle.compose(style: pair.style, document: pair.layers, state: state, apiBase: flow.api.app.apiBaseURL)
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

    /// Where the map last looked, where a new Private location starts (PrivacyViewController).
    static var lastCenter: CLLocationCoordinate2D?

    func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
        Self.lastCenter = mapView.centerCoordinate
    }

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
        styleLoaded = true
    }

    /// The tracks' lines a tap is asked about (TrackTap).
    var trackLayers: Set<String> { pair.map { TrackTap.layerIDs($0.layers) } ?? [] }

    // MARK: Modes and the Layers menu

    /// The mode picked on the Map tab, which state.mode shows there and comes back to after
    /// Stories (TabMode).
    var pickedMode = MapMode.normal

    /// The user's pick, shown at once on the Map tab.
    func pickMode(_ mode: MapMode) {
        pickedMode = mode
        MapPreferences.save(state, mode: pickedMode)
        applyTabMode()
    }

    /// The mode for the tab showing, and the toggle, which is only the Map tab's.
    func applyTabMode() {
        let onMap = panelTab == .activities
        modes.isHidden = !TabMode.toggleShown(onMapTab: onMap)
        let shown = TabMode.shown(picked: pickedMode, onMapTab: onMap)
        modes.selectedSegmentIndex = MapMode.allCases.firstIndex(of: pickedMode) ?? 0
        guard shown != state.mode else { return }
        state.mode = shown
        render()
        checkCoverage()
        renderPanel()
    }

    private func updateLayersMenu() {
        let hasSatellite = pair.map { MapStyle.hasSatellite($0.style) } ?? false
        func toggle(_ title: String, _ id: String, _ on: Bool, _ change: @escaping (inout MapState) -> Void) -> UIAction {
            UIAction(title: title, state: on ? .on : .off) { [weak self] _ in
                guard let self else { return }
                change(&self.state)
                MapPreferences.save(self.state, mode: self.pickedMode)
                self.render()
                self.updateLayersMenu()
            }
        }
        var items: [UIMenuElement] = [toggle(String(localized: "Show layers"), "showLayers", state.showLayers) { $0.showLayers.toggle() }]
        if hasSatellite {
            items.append(toggle(String(localized: "Satellite"), "satellite", state.satellite) { $0.satellite.toggle() })
        }
        items.append(toggle(String(localized: "Roads"), "roads", state.roads) { $0.roads.toggle() })
        let paths: [(String, String)] = [
            (String(localized: "Bike paths"), "bikePaths"),
            (String(localized: "Shared paths"), "sharedPaths"),
            (String(localized: "Mountain bike trails"), "mtbTrails"),
        ]
        let pathItems = paths.map { title, id in
            toggle(title, id, state.toggles[id] == true) { $0.toggles[id] = !($0.toggles[id] ?? false) }
        }
        items.append(UIMenu(title: String(localized: "Paths"), options: .displayInline, children: pathItems))
        layersButton.menu = UIMenu(title: String(localized: "Layers"), children: items)
    }

    // MARK: Framing

    /// Once per app session, the camera fits the most recent activity with a track
    /// (apps/android/docs/SPEC.md FR-2.3); an account with nothing on the map gets a pointer.
    private func frameOnce() {
        guard !Self.framed.contains(accountKey) else { return }
        Task {
            guard let rows = try? await flow.api.activities() else { return }
            Self.framed.insert(accountKey)
            guard let box = MapFraming.latest(rows) else {
                if !account.isDemo {
                    notice(.empty, String(localized: "Nothing on your map yet. Upload a GPX, FIT or TCX file from the You tab to see it here."))
                }
                return
            }
            hideNotice(.empty)
            fit(box, animated: false)
        }
    }

    /// The camera on box, clear of the controls over the map, at most zoom 15.
    func fit(_ box: [Double], animated: Bool) {
        let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: box[1], longitude: box[0]),
                                         ne: CLLocationCoordinate2D(latitude: box[3], longitude: box[2]))
        let bottom = (sheet.isHidden ? 0 : sheet.restingHeight) + 48
        let padding = UIEdgeInsets(top: 120, left: 48, bottom: bottom, right: 48)
        mapView.setVisibleCoordinateBounds(bounds, edgePadding: padding, animated: animated) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.mapView.zoomLevel > MapFraming.maxZoom else { return }
                self.mapView.setZoomLevel(MapFraming.maxZoom, animated: animated)
            }
        }
    }

    // MARK: Find my location

    private func locate() {
        switch location.authorizationStatus {
        case .notDetermined: location.requestWhenInUseAuthorization()
        case .denied, .restricted: notice(.location, String(localized: "HoldMyTrack needs location access to show where you are. Turn it on in Settings."))
        default: followUser()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            hideNotice(.location)
            followUser()
        default: break
        }
    }

    /// Flies to at least zoom 14 and follows the position until the map is panned.
    private func followUser() {
        mapView.showsUserLocation = true
        if mapView.zoomLevel < 14 { mapView.setZoomLevel(14, animated: false) }
        mapView.setUserTrackingMode(.follow, animated: true, completionHandler: nil)
    }

    // MARK: Coverage still updating

    /// Fog and Heatmap say when coverage is still being redrawn, checked on every opening of the
    /// map, and refresh when the server is done (root docs/SPEC.md FR-4.2).
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
                if status.rendering {
                    wasRendering = true
                    notice(.coverage, String(localized: "Your map is still being updated, so Fog and Heatmap may be incomplete for now. They'll refresh on their own."))
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

    func mapViewDidFinishRenderingMap(_ mapView: MLNMapView, fullyRendered: Bool) {
        if fullyRendered && !basemapLoaded {
            basemapLoaded = true
            updateBasemapNotice()
        }
    }

    func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
        basemapFailed = true
        updateBasemapNotice()
    }

    // MARK: Notices

    enum Notice: Int { case mapFailed, basemap, coverage, empty, location, pending }

    func notice(_ kind: Notice, _ text: String) {
        if let label = notices.arrangedSubviews.first(where: { $0.tag == kind.rawValue + 1 }) as? UILabel {
            label.text = text
            return
        }
        let label = Controls.body(text, color: UIColor(resource: .ink))
        label.tag = kind.rawValue + 1
        label.backgroundColor = UIColor(resource: .noticeBg)
        label.layer.cornerRadius = DesignTokens.Radius.md
        label.layer.masksToBounds = true
        label.textAlignment = .center
        label.accessibilityIdentifier = "notice"
        notices.addArrangedSubview(label)
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    func hideNotice(_ kind: Notice) {
        notices.arrangedSubviews.first { $0.tag == kind.rawValue + 1 }?.removeFromSuperview()
    }

    // MARK: Layout

    private func layoutChrome() {
        for (index, mode) in MapMode.allCases.enumerated() {
            let title = switch mode {
            case .normal: String(localized: "Normal")
            case .fog: String(localized: "Fog")
            case .heatmap: String(localized: "Heatmap")
            }
            modes.insertSegment(action: UIAction(title: title) { [weak self] _ in self?.pickMode(mode) }, at: index, animated: false)
        }
        modes.selectedSegmentIndex = MapMode.allCases.firstIndex(of: state.mode) ?? 0
        modes.backgroundColor = UIColor(resource: .surface)
        modes.accessibilityIdentifier = "modes"

        for (button, icon, label, id) in [
            (layersButton, UIImage(resource: .layers), String(localized: "Layers"), "layers"),
            (locateButton, UIImage(resource: .locateFixed), String(localized: "Find my location"), "locate"),
        ] {
            var config = UIButton.Configuration.filled()
            config.image = icon
            config.baseBackgroundColor = UIColor(resource: .surface)
            config.baseForegroundColor = UIColor(resource: .ink)
            config.cornerStyle = .capsule
            button.configuration = config
            button.accessibilityLabel = label
            button.accessibilityIdentifier = id
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        layersButton.showsMenuAsPrimaryAction = true
        locateButton.addAction(UIAction { [weak self] _ in self?.locate() }, for: .primaryActionTriggered)
        updateLayersMenu()

        for v in [modes, layersButton] { modesRow.addArrangedSubview(v) }
        modesRow.spacing = DesignTokens.Space.s8
        modesRow.alignment = .center
        let column = Controls.column([modesRow, notices], spacing: DesignTokens.Space.s8)
        bindSlider()

        for v in [column, locateButton, sheet] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: guide.topAnchor, constant: DesignTokens.Space.s8),
            column.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: DesignTokens.Space.s12),
            column.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -DesignTokens.Space.s12),
            sheet.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            sheet.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            sheet.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            locateButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -DesignTokens.Space.s12),
            locateButton.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -DesignTokens.Space.s32),
            locateButton.topAnchor.constraint(greaterThanOrEqualTo: column.bottomAnchor, constant: DesignTokens.Space.s8),
        ])
        // Above the sheet while it shows, else near the bottom.
        let aboveSheet = locateButton.bottomAnchor.constraint(equalTo: sheet.topAnchor, constant: -DesignTokens.Space.s12)
        aboveSheet.priority = .defaultHigh
        aboveSheet.isActive = true
    }

    /// What the map shows before the documents arrive: the background alone.
    private static let emptyStyle = ##"{"version":8,"sources":{},"layers":[{"id":"background","type":"background","paint":{"background-color":"#e8e4da"}}]}"##
}

/// The Layers menu, kept on the phone rather than the account (apps/android/docs/SPEC.md FR-2.2):
/// all off but Roads and Show layers until changed. The mode lasts the app session, through a
/// theme or language change.
@MainActor
enum MapPreferences {
    private static let defaults = UserDefaults.standard
    private static var mode = MapMode.normal

    static func restore(into state: inout MapState) {
        state.mode = mode
        state.satellite = defaults.bool(forKey: "map.satellite")
        state.roads = defaults.object(forKey: "map.roads") as? Bool ?? true
        state.showLayers = defaults.object(forKey: "map.showLayers") as? Bool ?? true
        state.toggles = defaults.dictionary(forKey: "map.toggles") as? [String: Bool] ?? [:]
    }

    /// mode is the Map tab's pick, which the map may not be showing on another tab.
    static func save(_ state: MapState, mode picked: MapMode) {
        mode = picked
        defaults.set(state.satellite, forKey: "map.satellite")
        defaults.set(state.roads, forKey: "map.roads")
        defaults.set(state.showLayers, forKey: "map.showLayers")
        defaults.set(state.toggles, forKey: "map.toggles")
    }
}
