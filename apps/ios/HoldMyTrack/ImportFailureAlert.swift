import HoldMyTrackCore
import UIKit

/// The alert for imports that failed on the server's side (root docs/SPEC.md FR-3.2): files
/// uploaded and tracks synced alike, each with its reason. A file the server can't use is refused
/// when it is sent, so only a fault on the server's side gets here. Checked when the signed-in
/// screen appears, when the app comes back to the front and when a sent recording fails; closing
/// the alert dismisses what it listed, so a later failure gets an alert of its own.
@MainActor
final class ImportFailureAlert {
    private let api: APIClient
    /// The demo account sends nothing, so it has nothing to fail.
    private let enabled: Bool
    /// A read for an alert is under way.
    private var reading = false
    /// The alert up. Weak: one taken down with the screen under it frees the next check, and what
    /// it listed, not dismissed, shows again.
    private weak var shown: UIAlertController?
    /// Dismissals still being sent: a read before they land would list the same failures again.
    private var dismissing = false

    init(api: APIClient, enabled: Bool) {
        self.api = api
        self.enabled = enabled
    }

    /// Reads the unseen failures and shows them over whatever host's window shows. A failed read
    /// is let go: the next check reads again.
    func check(over host: UIViewController) {
        guard enabled, !reading, !dismissing, shown?.presentingViewController == nil else { return }
        reading = true
        let api = api
        Task { [weak self, weak host] in
            guard let self else { return }
            let failures = (try? await api.importFailures()) ?? []
            self.reading = false
            guard !failures.isEmpty, let view = host?.viewIfLoaded, let top = TripDialogs.top(view) else { return }
            let alert = UIAlertController(title: String(localized: "import.failedTitle", defaultValue: "\(failures.count) imports couldn't be added",
                                                        comment: "The failed-imports alert's title; the number is how many it lists."),
                                          message: ImportFailure.message(failures), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { [weak self] _ in
                self?.dismissing = true
                // Dismissals outlive the screen that closed the alert.
                Task { [weak self] in
                    for failure in failures { try? await api.dismissImportFailure(failure.id) }
                    self?.dismissing = false
                }
            })
            alert.view.accessibilityIdentifier = "importFailures"
            top.present(alert, animated: true)
            // A screen mid-transition refuses it: nothing dismissed, so the next check shows the same failures.
            if alert.presentingViewController != nil { self.shown = alert }
        }
    }
}
