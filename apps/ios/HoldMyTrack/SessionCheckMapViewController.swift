import HoldMyTrackCore
import MapLibre
import UIKit

/// The map while a restored token waits for the server's word (apps/android/docs/SPEC.md
/// FR-1.2): the basemap alone, since the account's layers would be refused tiles were the token
/// revoked. "Checking your session…" shows once the check is slow enough to notice; a failure
/// other than a 401 says the server couldn't be reached and offers Try again. A confirmed
/// account replaces this screen with the signed-in app.
final class SessionCheckMapViewController: UIViewController, SessionCheckScreen {
    private unowned let flow: AppFlow
    private let documents: MapDocuments
    private var mapView: MLNMapView!
    private let notices = MapNotices()
    private var checkingDelay: Task<Void, Never>?
    private var shownStyle: String?

    private enum Notice: Int { case checking, unreachable }

    /// How long a check runs before its notice shows, so a fast one doesn't flash it (Android's
    /// CHECKING_DELAY_MS).
    private static let checkingDelay: Duration = .milliseconds(600)

    init(flow: AppFlow, stored: StoredSession) {
        self.flow = flow
        documents = MapDocuments(api: flow.api, account: AccountKey.of(email: stored.email, isDemo: stored.isDemo))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { checkingDelay?.cancel() }

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

    /// The basemap style kept for this account, then the server's; without either the map keeps
    /// its background, and the signed-in map reports the failure.
    private func loadBasemap() {
        let flavor = traitCollection.userInterfaceStyle == .dark ? "dark" : "light", language = AppLanguage.current
        if let kept = documents.kept(flavor: flavor, language: language) { showStyle(kept.style) }
        Task {
            guard let fetched = try? await documents.fetch(flavor: flavor, language: language) else { return }
            showStyle(fetched.style)
        }
    }

    private func showStyle(_ style: JSONValue) {
        guard let json = String(data: style.data, encoding: .utf8), json != shownStyle else { return }
        shownStyle = json
        mapView.styleJSON = json
    }

    func checkStarted() {
        checkingDelay?.cancel()
        checkingDelay = Task { [weak self] in
            try? await Task.sleep(for: Self.checkingDelay)
            guard !Task.isCancelled, let self else { return }
            notices.show(Notice.checking.rawValue, String(localized: "Checking your session…"))
        }
    }

    func checkFailed(_ error: APIError) {
        checkingDelay?.cancel()
        notices.hide(Notice.checking.rawValue)
        notices.show(Notice.unreachable.rawValue, String(localized: "Couldn't reach HoldMyTrack, so your tracks aren't on the map yet."),
                     action: (String(localized: "Try again"), { [weak self] in
                         self?.notices.hide(Notice.unreachable.rawValue)
                         self?.flow.check()
                     }))
    }
}