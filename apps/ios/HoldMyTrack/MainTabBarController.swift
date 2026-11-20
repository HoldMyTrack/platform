import HoldMyTrackCore
import UIKit

/// The signed-in app: Tracks, Trips, the record button, Sync and You
/// (apps/android/docs/SPEC.md FR-2.9), each tab keeping its state across a switch. Tracks and
/// Trips are one map screen with its sheet on the Tracks or the Trips tab
/// (MapHostViewController); Trips counts copies waiting to be answered. The record button sits
/// over an empty middle item, with the recording's status above it (RecordingController). The
/// tour runs over all of it (TourController).
final class MainTabBarController: UITabBarController, UITabBarControllerDelegate, TourHost {
    let map: MapViewController
    private let account: Account
    private lazy var tour = TourController(host: self)
    private let recorder: RecordingController
    private let recordButton = RecordButton()
    private let recordStatus = Controls.label("", font: Typeface.sans(DesignTokens.Text.md, weight: DesignTokens.Weight.semibold), color: UIColor(resource: .ink))
    private var holdingToStop = false
    /// Whether the leftover check has run for this screen, once on its first appearance.
    private var leftoverChecked = false
    /// The question about a leftover while it's up.
    private weak var leftoverAlert: UIAlertController?
    /// The middle item under the record button, never selected.
    private let gap = UIViewController()

    init(flow: AppFlow, account: Account) {
        let map = MapViewController(flow: flow, account: account)
        self.map = map
        self.account = account
        recorder = RecordingController(account: AccountKey.of(email: account.email, isDemo: account.isDemo))
        super.init(nibName: nil, bundle: nil)
        delegate = self
        let mapHost = MapHostViewController(map: map, tab: .tracks)
        mapHost.tabBarItem = UITabBarItem(title: String(localized: "Tracks"), image: UIImage(resource: .map), tag: 0)
        mapHost.tabBarItem.accessibilityIdentifier = "tabTracks"
        let trips = MapHostViewController(map: map, tab: .trips)
        trips.tabBarItem = UITabBarItem(title: String(localized: "Trips"), image: UIImage(resource: .bookOpen), tag: 1)
        trips.tabBarItem.accessibilityIdentifier = "tabTrips"
        let history = WebPageViewController(flow: flow, page: .syncHistory)
        let sync = UINavigationController(rootViewController: history)
        sync.tabBarItem = UITabBarItem(title: String(localized: "Sync"), image: UIImage(resource: .refreshCw), tag: 2)
        let home = YouViewController(flow: flow, account: account)
        let you = UINavigationController(rootViewController: home)
        you.navigationBar.prefersLargeTitles = false
        you.tabBarItem = UITabBarItem(title: String(localized: "You"), image: UIImage(resource: .user), tag: 3)
        you.tabBarItem.accessibilityIdentifier = "tabYou"
        gap.tabBarItem = UITabBarItem(title: nil, image: nil, tag: 4)
        gap.tabBarItem.isEnabled = false
        viewControllers = [mapHost, trips, gap, sync, you]
        tabBar.tintColor = UIColor(resource: .accent)
        tabBar.backgroundColor = UIColor(resource: .surface)
        sync.tabBarItem.accessibilityIdentifier = "tabSync"
        history.onViewOnMap = { [weak self, weak mapHost, weak map] track, day in
            guard let self, let mapHost, let map else { return }
            self.selectedViewController = mapHost
            map.viewOnMap(track: track, day: day)
        }
        home.onTour = { [weak self] in self?.tour.request() }
        map.onHistoryKnown = { [weak self] any in self?.tour.historyKnown(any) }
        map.onModePicked = { [weak self] mode in self?.tour.notice(.mode(mode)) }
        map.onMapFreed = { [weak self] in self?.tour.mapFreed() }
        map.onWaiting = { [weak trips] count in trips?.tabBarItem.badgeValue = count > 0 ? "\(count)" : nil }
        map.onWantsTrips = { [weak self, weak trips] id in
            guard let self, let trips else { return }
            trips.pendingTrip = id
            self.selectedViewController = trips
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        setUpRecording()
        NotificationCenter.default.addObserver(forName: RecordingResume.asked, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLeftover() }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !leftoverChecked {
            leftoverChecked = true
            checkLeftover()
        }
    }

    /// What a crash or a swipe left: resumed for the notification's tap, else asked about. A
    /// resume takes down the question about the same recording.
    private func checkLeftover() {
        recorder.checkLeftover(resumeAsked: RecordingResume.take())
        if recorder.state != .idle, let alert = leftoverAlert {
            alert.presentingViewController?.dismiss(animated: true)
            leftoverAlert = nil
        }
    }

    /// Over whatever is already presented, such as the Update screen or an opened file's Upload,
    /// which would otherwise keep the question from showing.
    private func presentOnTop(_ alert: UIAlertController) {
        var top: UIViewController = self
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        top.present(alert, animated: true)
    }

    private func askAboutLeftover(_ left: RecordingJournal.Leftover) {
        guard recorder.isCurrent(left) else { return }
        if let mapHost = viewControllers?.first { selectedViewController = mapHost }
        let format = PanelFormat(account: account)
        let message = String(localized: "recording.leftoverMessage", defaultValue: "HoldMyTrack was closed while recording. \(RecordingStatus.clock(left.moving)) · \(format.distance(left.meters)) was recorded before it stopped.", comment: "The prompt about a recording the app was closed in: its moving time and distance.")
        let alert = UIAlertController(title: String(localized: "recording.leftoverTitle", defaultValue: "Unfinished recording", comment: "The prompt about a recording the app was closed in."), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "recording.resume", defaultValue: "Resume", comment: "An unfinished recording: go on recording it."), style: .default) { [weak self] _ in
            self?.recorder.resume(left)
        })
        alert.addAction(UIAlertAction(title: String(localized: "recording.save", defaultValue: "Save", comment: "An unfinished recording: keep it as Stop would."), style: .default) { [weak self] _ in
            guard let self, self.recorder.isCurrent(left) else { return }
            self.map.say(self.recorder.save(left)
                ? String(localized: "recording.saved", defaultValue: "Recording saved on this phone.", comment: "Recording: Stop kept it on the phone.")
                : String(localized: "recording.tooShort", defaultValue: "Too short — not saved.", comment: "Recording: Stop on less than a minute or two points."))
        })
        alert.addAction(UIAlertAction(title: String(localized: "recording.discard", defaultValue: "Discard", comment: "An unfinished recording: delete it."), style: .destructive) { [weak self] _ in
            self?.confirmDiscard(left)
        })
        leftoverAlert = alert
        presentOnTop(alert)
    }

    /// Discard asks first: the copy on the phone is the only one.
    private func confirmDiscard(_ left: RecordingJournal.Leftover) {
        let alert = UIAlertController(title: String(localized: "recording.discardTitle", defaultValue: "Discard this recording?", comment: "Discarding an unfinished recording: the question."),
                                      message: String(localized: "recording.discardMessage", defaultValue: "The track will be deleted from this device. This can't be undone.", comment: "Discarding an unfinished recording: why it asks."),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak self] _ in self?.askAboutLeftover(left) })
        alert.addAction(UIAlertAction(title: String(localized: "recording.discard", defaultValue: "Discard", comment: "An unfinished recording: delete it."), style: .destructive) { [weak self] _ in
            self?.recorder.discard(left)
        })
        leftoverAlert = alert
        presentOnTop(alert)
    }

    // MARK: Recording

    private func setUpRecording() {
        recordStatus.textAlignment = .center
        recordStatus.backgroundColor = UIColor(resource: .surface)
        recordStatus.layer.cornerRadius = DesignTokens.Radius.md
        recordStatus.layer.masksToBounds = true
        recordStatus.accessibilityIdentifier = "recordStatus"
        recordStatus.isHidden = true
        view.addSubview(recordStatus)
        view.addSubview(recordButton)
        recordButton.onTap = { [weak self] in
            guard let self else { return }
            if RecordingStatus.showsMap(stopping: false, state: self.recorder.state) { self.showMap() }
            self.recorder.tap()
        }
        recordButton.onStop = { [weak self] in
            guard let self else { return }
            if RecordingStatus.showsMap(stopping: true, state: self.recorder.state) { self.showMap() }
            self.recorder.stop()
        }
        recordButton.onHolding = { [weak self] holding in
            self?.holdingToStop = holding
            self?.renderRecordingStatus()
        }
        recorder.onChange = { [weak self] in self?.renderRecording() }
        recorder.onTick = { [weak self] in self?.renderRecordingStatus() }
        recorder.onMessage = { [weak self] text in self?.map.say(text) }
        recorder.onRefused = { [weak self] in self?.offerLocationSettings() }
        recorder.onLeftover = { [weak self] left in self?.askAboutLeftover(left) }
    }

    /// The button over the middle item, by frame: the tab bar isn't in a hierarchy the
    /// controller's view can constrain to, and moves with its own layout.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bar = tabBar.convert(tabBar.bounds, to: view)
        let items = bar.height - tabBar.safeAreaInsets.bottom
        let side = RecordButton.side
        recordButton.frame = CGRect(x: bar.midX - side / 2, y: bar.minY + items / 2 - side / 2, width: side, height: side)
        let fit = recordStatus.sizeThatFits(CGSize(width: view.bounds.width - 2 * DesignTokens.Space.s16, height: .greatestFiniteMagnitude))
        let width = min(fit.width, view.bounds.width - 2 * DesignTokens.Space.s16), height = max(fit.height + DesignTokens.Space.s8, 28)
        recordStatus.frame = CGRect(x: bar.midX - width / 2, y: recordButton.frame.minY - DesignTokens.Space.s8 - height, width: width, height: height)
    }

    /// The recording's state or fixes changed: the button, the status and the map.
    private func renderRecording() {
        recordButton.recordingState = recorder.state
        renderRecordingStatus()
        map.showRecording(active: recorder.state != .idle, points: recorder.recording.points)
    }

    /// The status line alone, every second of the clock.
    private func renderRecordingStatus() {
        let status = recorder.status(format: PanelFormat(account: account), holding: holdingToStop, at: Date())
        recordStatus.text = status.map { "  \($0)  " }
        recordStatus.isHidden = status == nil
        view.setNeedsLayout()
    }

    /// The Tracks tab, where the recording is drawn and its outcome said.
    private func showMap() {
        guard let mapHost = viewControllers?.first, selectedViewController !== mapHost else { return }
        selectedViewController = mapHost
    }

    /// The signed-in screen is going: a sign-out or an ended session keeps the recording as a
    /// Stop would, and a deleted account's is dropped with everything else it had.
    func endRecording(save: Bool) {
        recorder.end(save: save)
    }

    /// Location is off for HoldMyTrack: Settings is where it's turned on.
    private func offerLocationSettings() {
        let alert = UIAlertController(title: nil, message: RecordingController.needsLocation, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Settings"), style: .default) { _ in
            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        })
        present(alert, animated: true)
    }

    /// The middle item is the record button's place, never a tab.
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        viewController !== gap
    }

    /// The user's own pick of a tab, which may earn the Trips card.
    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        tour.notice(.tab(tourTab))
    }

    // MARK: The tour

    var isDemo: Bool { account.isDemo }

    /// The tab bar's items, the record button's empty one in the middle.
    private static let tourTabs: [TourTab?] = [.map, .trips, nil, .sync, .you]

    var tourTab: TourTab { Self.tourTabs[min(selectedIndex, Self.tourTabs.count - 1)] ?? .map }

    func showTourTab(_ tab: TourTab, root: Bool) {
        guard let index = Self.tourTabs.firstIndex(of: tab), let next = viewControllers?[index] else { return }
        if root { (next as? UINavigationController)?.popToRootViewController(animated: false) }
        selectedViewController = next
    }

    func tourViews(_ target: TourTarget) -> [UIView] {
        switch target {
        case .page:
            guard let page = (selectedViewController as? UINavigationController)?.topViewController?.view else { return [] }
            return [page]
        case .youTour: return youHome?.tourCell.map { [$0] } ?? []
        default:
            // The map's controls only while a map tab shows it.
            return tourTab == .map || tourTab == .trips ? map.tourViews(target) : []
        }
    }

    func revealTourTarget(_ target: TourTarget) {
        if target == .youTour { youHome?.revealTour() }
    }

    var tourContainer: UIView { view }

    private var youHome: YouViewController? {
        (viewControllers?.last as? UINavigationController)?.viewControllers.first as? YouViewController
    }

    /// Privacy's row or Add: the map, with the editor on a saved location's id or a new one.
    func editPrivateLocation(_ id: String?) {
        guard let mapHost = viewControllers?.first, let you = viewControllers?.last as? UINavigationController else { return }
        selectedViewController = mapHost
        you.popToRootViewController(animated: false)
        map.editPrivateLocation(id)
    }

    /// Files opened or shared from another app: Upload on the You tab, for an account that can.
    func upload(_ files: [URL]) {
        guard let you = viewControllers?.last as? UINavigationController, let home = you.viewControllers.first as? YouViewController else { return }
        selectedViewController = you
        home.upload(files)
    }
}
