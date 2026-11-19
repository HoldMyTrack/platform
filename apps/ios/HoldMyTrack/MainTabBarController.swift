import HoldMyTrackCore
import UIKit

/// The signed-in app: Tracks, Trips, Sync and You (apps/android/docs/SPEC.md FR-2.9), each keeping
/// its state across a switch. Tracks and Trips are one map screen with its sheet on the Tracks
/// or the Trips tab (MapHostViewController); Trips counts copies waiting to be answered. The
/// record button comes with recording (ROADMAP.md, 7d).
final class MainTabBarController: UITabBarController {
    private let map: MapViewController

    init(flow: AppFlow, account: Account) {
        let map = MapViewController(flow: flow, account: account)
        self.map = map
        super.init(nibName: nil, bundle: nil)
        let mapHost = MapHostViewController(map: map, tab: .tracks)
        mapHost.tabBarItem = UITabBarItem(title: String(localized: "Tracks"), image: UIImage(resource: .map), tag: 0)
        mapHost.tabBarItem.accessibilityIdentifier = "tabTracks"
        let trips = MapHostViewController(map: map, tab: .trips)
        trips.tabBarItem = UITabBarItem(title: String(localized: "Trips"), image: UIImage(resource: .bookOpen), tag: 1)
        trips.tabBarItem.accessibilityIdentifier = "tabTrips"
        let history = WebPageViewController(flow: flow, page: .syncHistory)
        let sync = UINavigationController(rootViewController: history)
        sync.tabBarItem = UITabBarItem(title: String(localized: "Sync"), image: UIImage(resource: .refreshCw), tag: 2)
        let you = UINavigationController(rootViewController: YouViewController(flow: flow, account: account))
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
        map.onWaiting = { [weak trips] count in trips?.tabBarItem.badgeValue = count > 0 ? "\(count)" : nil }
        map.onWantsTrips = { [weak self, weak trips] id in
            guard let self, let trips else { return }
            trips.pendingTrip = id
            self.selectedViewController = trips
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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
