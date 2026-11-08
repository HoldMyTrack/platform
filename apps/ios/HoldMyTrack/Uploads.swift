import HoldMyTrackCore
import UIKit

/// The files Upload sends to `POST /v1/activities/upload` (apps/android/docs/SPEC.md FR-3.6): the
/// web upload's checks (UploadPlan), then each file on a background URLSession, so they carry on
/// when the app is left. The session allows one connection to the API, which sends the queue one
/// file at a time without the app waking between them (apps/ios/docs/IMPLEMENTATION.md §4.4).
@MainActor
final class Uploads: NSObject, URLSessionDataDelegate {
    static let shared = Uploads()
    static let changed = Notification.Name("Uploads.changed")
    static let sessionID = "dev.holdmytrack.ios.uploads"

    /// One file going: bytes sent of its body's size.
    struct Transfer {
        let name: String
        var sent: Int64 = 0
        var total: Int64 = 0
    }

    /// What a finished upload said that Sync history won't, or why a picked file wasn't sent.
    struct Note {
        let text: String
        let error: Bool
    }

    var api: APIClient?
    private(set) var transfers: [Int: Transfer] = [:]
    private(set) var notes: [Note] = []
    /// Bumped as each file goes, so the screen knows to look at the running imports.
    private(set) var sentCount = 0
    /// iOS's handler for the session's events after a background launch.
    var backgroundCompletion: (() -> Void)?
    private var bodies: [Int: Data] = [:]
    /// Each task's multipart file, deleted once sent.
    private var files: [Int: URL] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.httpMaximumConnectionsPerHost = 1
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    /// Makes the session, so a background launch's events have a delegate.
    func reconnect() { _ = session }

    /// Queues urls as the web's upload does; what it refuses is named in a note.
    func enqueue(_ urls: [URL]) {
        guard let api else { return }
        notes = []
        let picked = urls.map { url -> UploadPlan.Picked in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            return UploadPlan.Picked(name: url.lastPathComponent, size: size)
        }
        let plan = UploadPlan.of(picked)
        for refusal in plan.refusals {
            let text = switch refusal {
            case .zip(let name): String(localized: "\(name): archives aren't imported. Upload the GPX, FIT or TCX files inside it.")
            case .wrongType(let name): String(localized: "\(name) isn't a GPX, FIT or TCX file.")
            case .tooMany(let count): String(localized: "You picked \(count) activity files. Upload at most \(UploadPlan.maxFiles) at a time.")
            case .tooLarge(let name): String(localized: "\(name) is over \(UploadPlan.maxFileBytes >> 20) MB.")
            }
            notes.append(Note(text: text, error: true))
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "uploads")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in plan.send {
            let url = urls[i], name = picked[i].name
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let boundary = "hmt-\(UUID().uuidString)"
            let body = dir.appending(path: UUID().uuidString)
            do {
                try UploadBody.write(file: url, name: name, boundary: boundary, to: body)
            } catch {
                notes.append(Note(text: String(localized: "\(name) couldn't be read."), error: true))
                continue
            }
            let task = session.uploadTask(with: api.uploadRequest(boundary: boundary), fromFile: body)
            task.taskDescription = name
            files[task.taskIdentifier] = body
            transfers[task.taskIdentifier] = Transfer(name: name)
            task.resume()
        }
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: URLSessionDataDelegate, on the main queue

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData _: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        MainActor.assumeIsolated {
            transfers[task.taskIdentifier, default: Transfer(name: task.taskDescription ?? "")].sent = totalBytesSent
            transfers[task.taskIdentifier]?.total = totalBytesExpectedToSend
            changed()
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated { bodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            let name = task.taskDescription ?? ""
            let body = bodies.removeValue(forKey: task.taskIdentifier) ?? Data()
            transfers[task.taskIdentifier] = nil
            if let file = files.removeValue(forKey: task.taskIdentifier) { try? FileManager.default.removeItem(at: file) }
            sentCount += 1
            if error != nil {
                notes.append(Note(text: String(localized: "\(name) wasn't sent: the server couldn't be reached."), error: true))
            } else {
                let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 426 { NotificationCenter.default.post(name: Self.outdated, object: nil) }
                switch APIClient.uploadOutcome(status: status, body: body) {
                case .sent: break
                case .already: notes.append(Note(text: String(localized: "\(name) was imported before."), error: false))
                case .refused(let reason):
                    notes.append(Note(text: String(localized: "\(name) wasn't sent: \(reason.isEmpty ? String(localized: "the server refused it.") : reason)"), error: true))
                }
            }
            changed()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            backgroundCompletion?()
            backgroundCompletion = nil
        }
    }

    /// A background upload's `426`: the app's flow shows the Update screen.
    static let outdated = Notification.Name("Uploads.outdated")
}