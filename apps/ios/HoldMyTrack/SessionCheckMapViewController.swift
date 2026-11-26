import HoldMyTrackCore
import MapLibre
import UIKit

/// The map while a restored token waits for the server's word (apps/docs/SPEC.md
/// FR-1.2): the basemap alone, since the account's layers would be refused tiles were the token
/// revoked. Which notice shows is SessionCheckNotice's; the unreachable one offers Sign out
/// beside Try again, since the tab bar and its You tab wait for the check. A confirmed account
/// replaces this screen with the signed-in app.
final class SessionCheckMapViewController: UIViewController, SessionCheckScreen {
    private unowned let flow: AppFlow
    private let documents: MapDocuments
    private var mapView: MLNMapView!
    private let notices = MapNotices()
    private var shown: SessionCheckNotice?
    private var slowTimer: Task<Void, Never>?
    private var basemapTask: Task<Void, Never>?
    private var shownStyle: String?

    init(flow: AppFlow, stored: StoredSession) {
        self.flow = flow
        documents = MapDocuments(api: flow.api, account: AccountKey.of(email: stored.email, isDemo: stored.isDemo))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        slowTimer?.cancel()
        basemapTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .bg)
        mapView = MLNMapView(frame: view.bounds)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.styleJSON = MapViewController.emptyStyle
        mapView.setCenter(CLLocationCoordinate2D(latitude: 20, longitude: 0), zoomLevel: 1, animated: false)
        mapView.logoViewPosition = .bottomLeft
        mapView.attributionButtonPosition = .bottomLeft
        mapView.accessibilityIdentifier = "map"
        view.addSubview(mapView)
        notices.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(notices)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            notices.topAnchor.constraint(equalTo: guide.topAnchor, constant: DesignTokens.Space.s8),
            notices.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: DesignTokens.Space.s12),
            notices.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -DesignTokens.Space.s12),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.loadBasemap() }
        loadBasemap()
    }

    /// The kept style, then the server's, with the map's Satellite and Roads applied
    /// (MapStyle.basemap); a fetch for an earlier theme is dropped.
    private func loadBasemap() {
        basemapTask?.cancel()
        let flavor = traitCollection.userInterfaceStyle == .dark ? "dark" : "light", language = AppLanguage.current
        if let kept = documents.keptStyle(flavor: flavor, language: language) { showStyle(kept) }
        let documents = documents
        basemapTask = Task { [weak self] in
            guard let fetched = try? await documents.fetchStyle(flavor: flavor, language: language), !Task.isCancelled else { return }
            self?.showStyle(fetched)
        }
    }

    private func showStyle(_ style: JSONValue) {
        var state = MapState()
        MapPreferences.restore(into: &state)
        let composed = MapStyle.basemap(style: style, state: state)
        guard let json = String(data: composed.data, encoding: .utf8), json != shownStyle else { return }
        shownStyle = json
        mapView.styleJSON = json
    }

    func checkStarted() {
        apply(.started)
        slowTimer?.cancel()
        slowTimer = Task { [weak self] in
            try? await Task.sleep(for: SessionCheckNotice.checkingDelay)
            guard !Task.isCancelled else { return }
            self?.apply(.slow)
        }
    }

    func checkFailed(_ error: APIError) {
        slowTimer?.cancel()
        apply(.failed(error))
    }

    private func apply(_ event: SessionCheckNotice.Event) {
        let next = SessionCheckNotice.after(event, shown: shown)
        guard next != shown else { return }
        if let shown { notices.hide(Self.id(shown)) }
        shown = next
        switch next {
        case .checking:
            notices.show(Self.id(.checking), String(localized: "Checking your session…"))
        case .unreachable:
            notices.show(Self.id(.unreachable), String(localized: "Couldn't reach HoldMyTrack, so your tracks aren't on the map yet."), actions: [
                MapNotices.Action(title: String(localized: "Try again"), id: "noticeAction") { [weak self] in self?.flow.check() },
                MapNotices.Action(title: String(localized: "Sign out"), id: "signOut") { [weak self] in self?.flow.signOut() },
            ])
        case nil:
            break
        }
    }

    private static func id(_ notice: SessionCheckNotice) -> Int {
        switch notice {
        case .checking: 0
        case .unreachable: 1
        }
    }
}