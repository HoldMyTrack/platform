import HoldMyTrackCore
import UIKit

/// The signed-in app: Map, Stories, Sync and You (apps/android/docs/SPEC.md FR-2.9), each keeping
/// its state across a switch. Map and Stories are one map screen with its sheet on the Activities
/// or the Stories tab (MapHostViewController); Stories counts copies waiting to be answered. The
/// record button comes with recording (ROADMAP.md, 7d).
final class MainTabBarController: UITabBarController {
    init(flow: AppFlow, account: Account) {
        super.init(nibName: nil, bundle: nil)
        let map = MapViewController(flow: flow, account: account)
        let mapHost = MapHostViewController(map: map, tab: .activities)
        mapHost.tabBarItem = UITabBarItem(title: String(localized: "Map"), image: UIImage(resource: .map), tag: 0)
        mapHost.tabBarItem.accessibilityIdentifier = "tabMap"
        let stories = MapHostViewController(map: map, tab: .stories)
        stories.tabBarItem = UITabBarItem(title: String(localized: "Stories"), image: UIImage(resource: .bookOpen), tag: 1)
        stories.tabBarItem.accessibilityIdentifier = "tabStories"
        let sync = PlaceholderViewController(text: String(localized: "Sync history comes with the site's pages."))
        sync.tabBarItem = UITabBarItem(title: String(localized: "Sync"), image: UIImage(resource: .refreshCw), tag: 2)
        let you = HomeViewController(flow: flow, account: account)
        you.tabBarItem = UITabBarItem(title: String(localized: "You"), image: UIImage(resource: .user), tag: 3)
        you.tabBarItem.accessibilityIdentifier = "tabYou"
        viewControllers = [mapHost, stories, sync, you]
        tabBar.tintColor = UIColor(resource: .accent)
        tabBar.backgroundColor = UIColor(resource: .surface)
        map.onWaiting = { [weak stories] count in stories?.tabBarItem.badgeValue = count > 0 ? "\(count)" : nil }
        map.onWantsStories = { [weak self, weak stories] id in
            guard let self, let stories else { return }
            stories.pendingStory = id
            self.selectedViewController = stories
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// A tab whose screen is still to come, saying when.
final class PlaceholderViewController: UIViewController {
    private let text: String

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .bg)
        let label = Controls.body(text)
        label.textAlignment = .center
        Controls.host(Controls.column([label]), in: self)
    }
}
