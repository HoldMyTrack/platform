import HoldMyTrackCore
import UIKit

/// The signed-in app: Map, Trips, Sync and You (apps/android/docs/SPEC.md FR-2.9), each keeping
/// its state across a switch. Map and Trips are one map screen with its sheet on the Tracks
/// or the Trips tab (MapHostViewController); Trips counts copies waiting to be answered. The
/// record button comes with recording (ROADMAP.md, 7d). The tour runs over all four
/// (TourController).
final class MainTabBarController: UITabBarController, UITabBarControllerDelegate, TourHost {
    let map: MapViewController
    private let account: Account
    private lazy var tour = TourController(host: self)

    init(flow: AppFlow, account: Account) {
        let map = MapViewController(flow: flow, account: account)
        self.map = map
        self.account = account
        super.init(nibName: nil, bundle: nil)
        delegate = self
        let mapHost = MapHostViewController(map: map, tab: .tracks)
        mapHost.tabBarItem = UITabBarItem(title: String(localized: "Map"), image: UIImage(resource: .map), tag: 0)
        mapHost.tabBarItem.accessibilityIdentifier = "tabMap"
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
        viewControllers = [mapHost, trips, sync, you]
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
        map.onWaiting = { [weak trips] count in trips?.tabBarItem.badgeValue = count > 0 ? "\(count)" : nil }
        map.onWantsTrips = { [weak self, weak trips] id in
            guard let self, let trips else { return }
            trips.pendingTrip = id
            self.selectedViewController = trips
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The user's own pick of a tab, which may earn the Trips card.
    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        tour.notice(.tab(tourTab))
    }

    // MARK: The tour

    var isDemo: Bool { account.isDemo }

    private static let tourTabs: [TourTab] = [.map, .trips, .sync, .you]

    var tourTab: TourTab { Self.tourTabs[min(selectedIndex, Self.tourTabs.count - 1)] }

    func showTourTab(_ tab: TourTab) {
        guard let index = Self.tourTabs.firstIndex(of: tab), let next = viewControllers?[index] else { return }
        (next as? UINavigationController)?.popToRootViewController(animated: false)
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
