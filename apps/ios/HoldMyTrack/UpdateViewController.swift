import UIKit

/// Over everything once the server turns this build away (`426 app_outdated`,
/// apps/android/docs/SPEC.md FR-1.8), and on every screen after it for the rest of the run.
/// Nothing on the phone changes. Update opens the App Store listing once there is one
/// (apps/ios/docs/ROADMAP.md, 10.2); until then the screen only says why the app stopped.
final class UpdateViewController: UIViewController {
    /// The App Store listing, set once the app has one.
    static let listing: URL? = nil

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .bg)
        view.accessibilityIdentifier = "update"
        var views: [UIView] = [
            Controls.title(String(localized: "Update HoldMyTrack")),
            Controls.body(String(localized: "update.body", defaultValue: "This version of the app is too old to use. Update it to keep using HoldMyTrack. Anything waiting to sync stays on your phone until then.", comment: "The Update screen: why, and what waits.")),
        ]
        if let listing = Self.listing {
            let update = Controls.primaryButton(String(localized: "Update"), id: "updateApp")
            update.addAction(UIAction { _ in UIApplication.shared.open(listing) }, for: .primaryActionTriggered)
            views.append(update)
        }
        Controls.host(Controls.column(views, spacing: DesignTokens.Space.s16), in: self)
    }
}
