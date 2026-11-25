import HoldMyTrackCore
import UIKit

/// Download (root docs/SPEC.md FR-17.2), the Tracks panel's: the tracks as one GPX, or a zip of
/// them, fetched into a temporary file and handed to the share sheet, whose Save to Files keeps
/// it. The file's directory goes once the sheet closes. One download at a time: a second tapped
/// while the first is fetched is refused with a word.
@MainActor
final class TrackDownload {
    private let api: APIClient
    /// A download is under way.
    private(set) var busy = false

    init(api: APIClient) {
        self.api = api
    }

    /// Downloads ids and offers the file over whatever shows then; say reports progress and
    /// failures over the map or the list.
    func start(_ ids: [String], from host: UIViewController, say: @escaping (String) -> Void) {
        guard !ids.isEmpty else { return }
        if busy {
            say(String(localized: "download.busy", defaultValue: "Another download is still being prepared", comment: "Download: a second one tapped while the first is still being fetched."))
            return
        }
        busy = true
        say(String(localized: "download.started", defaultValue: "Downloading…", comment: "Download: the tracks are being fetched."))
        Task { [weak self, weak host] in
            defer { self?.busy = false }
            do {
                guard let file = try await self?.api.downloadTracksGPX(ids) else { return }
                let dir = file.deletingLastPathComponent()
                guard let top = host.flatMap(Self.top) else {
                    try? FileManager.default.removeItem(at: dir)
                    return
                }
                let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                share.popoverPresentationController?.sourceView = top.view
                share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: dir) }
                // A screen still closing over top refuses a presentation until it has gone.
                if let closing = top.presentedViewController?.transitionCoordinator {
                    closing.animate(alongsideTransition: nil) { _ in top.present(share, animated: true) }
                } else {
                    top.present(share, animated: true)
                }
            } catch is CancellationError {
            } catch {
                say((error as? APIError)?.serverMessage ?? String(localized: "download.failed", defaultValue: "The tracks couldn't be downloaded. Check your connection and try again.",
                                                                    comment: "Download: the request failed with no word from the server."))
            }
        }
    }

    /// What the sheet goes over: the topmost screen of host's window, so a download that lands
    /// after the user moved to another tab still shows; nil once host left the screen, as at a
    /// sign-out.
    private static func top(_ host: UIViewController) -> UIViewController? {
        guard var top = host.view.window?.rootViewController ?? host.tabBarController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}
