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
    /// The recordings on the phone and their sending, followed on every tab.
    private let recordings: RecordingsSync
    private let recordButton = RecordButton()
    private let recordStatus = Controls.label("", font: Typeface.sans(DesignTokens.Text.md, weight: DesignTokens.Weight.semibold), color: UIColor(resource: .ink))
    private var holdingToStop = false
    /// Whether the leftover check has run for this screen, once on its first appearance.
    private var leftoverChecked = false
    /// The Live Activity's Stop question while it's up, taken down when the recording ends otherwise.
    private weak var stopAlert: UIAlertController?
    /// The question about a leftover while it's up.
    private weak var leftoverAlert: UIAlertController?
    /// The middle item under the record button, never selected.
    private let gap = UIViewController()

    init(flow: AppFlow, account: Account) {
        let map = MapViewController(flow: flow, account: account)
        self.map = map
        self.account = account
        recorder = RecordingController(account: AccountKey.of(email: account.email, isDemo: account.isDemo))
        recordings = RecordingsSync(api: flow.api, account: AccountKey.of(email: account.email, isDemo: account.isDemo), isDemo: account.isDemo)
        super.init(nibName: nil, bundle: nil)
        delegate = self
        let mapHost = MapHostViewController(map: map, tab: .tracks)
        mapHost.tabBarItem = UITabBarItem(title: String(localized: "Tracks"), image: UIImage(resource: .map), tag: 0)
        mapHost.tabBarItem.accessibilityIdentifier = "tabTracks"
        let trips = MapHostViewController(map: map, tab: .trips)
        trips.tabBarItem = UITabBarItem(title: String(localized: "Trips"), image: UIImage(resource: .bookOpen), tag: 1)
        trips.tabBarItem.accessibilityIdentifier = "tabTrips"
        let syncList = SyncViewController(flow: flow, account: account, recordings: recordings)
        let sync = UINavigationController(rootViewController: syncList)
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
        syncList.onViewOnMap = { [weak self, weak mapHost, weak map] track, day in
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
            // Saved, it opens for naming as a Stop's does.
            if let saved = self.recorder.save(left) {
                self.openRecording(saved)
            } else {
                self.map.say(String(localized: "recording.tooShort", defaultValue: "Too short — not saved.", comment: "Recording: Stop on less than a minute or two points."))
            }
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
        recorder.format = PanelFormat(account: account)
        recorder.onChange = { [weak self] in self?.renderRecording() }
        recorder.onTick = { [weak self] in self?.renderRecordingStatus() }
        recorder.onMessage = { [weak self] text in self?.map.say(text) }
        recorder.onRefused = { [weak self] in self?.offerLocationSettings() }
        recorder.onLeftover = { [weak self] left in self?.askAboutLeftover(left) }
        // Stop opens the new recording for naming, on the Sync tab where it's listed.
        recorder.onSaved = { [weak self] track in self?.openRecording(track) }
        recordings.onLanded = { [weak self] in self?.map.recordingLanded() }
        recordings.onFailed = { [weak self] in
            self?.map.say(String(localized: "sync.failed", defaultValue: "A recording couldn't be added. It's back on the Sync tab; Sync history says why.", comment: "Sync: a sent recording's ingest failed."))
        }
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
        if recorder.state == .idle, let alert = stopAlert {
            alert.presentingViewController?.dismiss(animated: true)
            stopAlert = nil
        }
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

    /// The Live Activity's Stop opened the app: it asks first, since a tap on the Lock Screen is
    /// easy to make by mistake.
    func askToStop() {
        // One question at a time: a second tap on the Lock Screen's Stop finds it up.
        guard recorder.state != .idle, stopAlert == nil else { return }
        showMap()
        let left = recorder.recording
        let format = PanelFormat(account: account)
        let message = String(localized: "recording.stopMessage", defaultValue: "\(RecordingStatus.clock(left.moving(at: Date()))) · \(format.distance(left.meters)) recorded so far.", comment: "Stopping from the Live Activity: the moving time and distance so far.")
        let alert = UIAlertController(title: String(localized: "recording.stopTitle", defaultValue: "Stop recording?", comment: "Stopping from the Live Activity: the question."), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "recording.keep", defaultValue: "Keep recording", comment: "Stopping from the Live Activity: don't."), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "activity.stop", defaultValue: "Stop", comment: "The recording's Live Activity: stop, which opens the app to ask first."), style: .destructive) { [weak self] _ in
            self?.recorder.stop()
        })
        stopAlert = alert
        presentOnTop(alert)
    }

    /// The signed-in screen is going: a sign-out or an ended session keeps the recording as a
    /// Stop would, and a deleted account's is dropped with everything else it had.
    func endRecording(save: Bool) {
        recorder.end(save: save)
        recordings.stop()
    }

    private func openRecording(_ track: RecordedTrack) {
        guard let sync = viewControllers?[3] as? UINavigationController, let list = sync.viewControllers.first as? SyncViewController else { return }
        sync.popToRootViewController(animated: false)
        selectedViewController = sync
        list.edit(track)
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
        case .record: return [recordButton]
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
