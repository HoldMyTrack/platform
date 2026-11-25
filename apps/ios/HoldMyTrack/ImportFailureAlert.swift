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
    /// An alert is up, or a read for one is under way: a second check waits for it to close.
    private var busy = false

    init(api: APIClient, enabled: Bool) {
        self.api = api
        self.enabled = enabled
    }

    /// Reads the unseen failures and shows them over whatever host's window shows. A failed read
    /// is let go: the next check reads again.
    func check(over host: UIViewController) {
        guard enabled, !busy else { return }
        busy = true
        let api = api
        Task { [weak self, weak host] in
            guard let self else { return }
            let failures = (try? await api.importFailures()) ?? []
            guard !failures.isEmpty, let view = host?.viewIfLoaded, let top = TripDialogs.top(view) else {
                self.busy = false
                return
            }
            let alert = UIAlertController(title: String(localized: "import.failedTitle", defaultValue: "\(failures.count) imports couldn't be added",
                                                        comment: "The failed-imports alert's title; the number is how many it lists."),
                                          message: ImportFailure.message(failures), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { [weak self] _ in
                self?.busy = false
                // Dismissals outlive the screen that closed the alert.
                Task.detached { for failure in failures { try? await api.dismissImportFailure(failure.id) } }
            })
            alert.view.accessibilityIdentifier = "importFailures"
            top.present(alert, animated: true)
            // A screen mid-transition refuses it: nothing dismissed, so the next check shows the same failures.
            if alert.presentingViewController == nil { self.busy = false }
        }
    }
}
