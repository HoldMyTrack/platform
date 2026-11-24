import HoldMyTrackCore
import UIKit

/// The panel's small dialogs: a confirmation, a notice, and Add to trip's menu. A confirmation
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

    /// Add to trip (FR-13.2, FR-13.3): the account's Trips, read as the menu opens, and New
    /// trip…; either takes targets() in one request. added reports the Trip, and whether it's new.
    static func addToTripMenu(api: APIClient, over view: UIView, targets: @escaping () -> [String],
                               added: @escaping (Trip, _ created: Bool) -> Void) -> UIMenu {
        let create = UIAction(title: String(localized: "New trip…"), image: UIImage(resource: .plus)) { [weak view] _ in
            guard let view else { return }
            TripSheets.trip(over: view, title: String(localized: "Create trip"), name: "", description: "", action: String(localized: "Create trip"),
                            busy: String(localized: "Creating…")) { name, description in
                do {
                    let read = try await api.createTrip(name: name, description: description, trackIDs: targets())
                    added(read.trip, true)
                    return nil
                } catch {
                    return TripsPanel.message(error, String(localized: "Could not save the trip"))
                }
            }
        }
        let trips = UIDeferredMenuElement.uncached { [weak view] completion in
            Task { @MainActor in
                guard let read = try? await api.trips() else {
                    completion([UIAction(title: String(localized: "Could not load your trips"), attributes: .disabled) { _ in }])
                    return
                }
                completion(read.map { item in
                    UIAction(title: item.trip.name) { [weak view] _ in
                        Task {
                            do {
                                let changed = try await api.changeTripTracks(item.trip.id, trackIDs: targets(), add: true)
                                added(changed.trip, false)
                            } catch {
                                if let view { inform(over: view, TripsPanel.message(error, String(localized: "Could not save the trip"))) }
                            }
                        }
                    }
                })
            }
        }
        return UIMenu(title: String(localized: "Add to trip"), children: [create, UIMenu(options: .displayInline, children: [trips])])
    }
}