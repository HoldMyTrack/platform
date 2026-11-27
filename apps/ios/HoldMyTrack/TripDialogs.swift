import HoldMyTrackCore
import UIKit

/// The panel's small dialogs: a confirmation, a notice, and New trip… from Add to trip. A confirmation
/// runs its request after the alert closes and, when it fails, opens again with the server's
/// reason. A Trip's name and Send a copy are sheets (TripSheets).
@MainActor
enum TripDialogs {
    /// What a dialog's request answers: nil once done, else why it failed.
    typealias Outcome = String?

    static func top(_ view: UIView) -> UIViewController? {
        var top = view.window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    /// A destructive action confirmed first; a failure is shown with the chance to try again.
    static func confirm(over view: UIView, title: String, message: String, action: String, run: @escaping () async -> Outcome) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: action, style: .destructive) { [weak view] _ in
            Task {
                guard let failure = await run(), let view else { return }
                Self.confirm(over: view, title: title, message: failure, action: action, run: run)
            }
        })
        top(view)?.present(alert, animated: true)
    }

    static func inform(over view: UIView, _ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        top(view)?.present(alert, animated: true)
    }

    /// New trip… from Add to trip (FR-13.2): a name, then the Trip made with targets in one
    /// request; created hears it.
    static func newTrip(api: APIClient, over view: UIView, targets: [String], created: @escaping (Trip) -> Void) {
        TripSheets.trip(over: view, title: String(localized: "Create trip"), name: "", description: "", action: String(localized: "Create trip"),
                        busy: String(localized: "Creating…")) { name, description in
            do {
                let read = try await api.createTrip(name: name, description: description, trackIDs: targets)
                created(read.trip)
                return nil
            } catch {
                return TripsPanel.message(error, String(localized: "Could not save the trip"))
            }
        }
    }
}