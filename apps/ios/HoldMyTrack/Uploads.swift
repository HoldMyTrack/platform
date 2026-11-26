import HoldMyTrackCore
import UIKit

/// The files Upload sends to `POST /v2/tracks/upload` (apps/android/docs/SPEC.md FR-3.6): the
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

    /// What a finished upload said, or why a picked file wasn't sent.
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
    /// Files another app opened here, listed on Upload until its Upload or Cancel, for as long as
    /// the session lasts.
    private(set) var shared = SharedFiles()
    /// The tokens of sessions that ended this run: their tasks leave no note (UploadTasks).
    private var endedTokens: Set<String> = []
    /// Where iOS copies a file another app opens here; such a copy is the app's to delete.
    private let inbox = URL.documentsDirectory.appending(path: "Inbox")

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
            case .zip(let name): String(localized: "\(name) is a .zip archive, which can't be imported. Upload the GPX, FIT or TCX files inside it instead.")
            case .wrongType(let name): String(localized: "\(name) isn't a .gpx, .fit or .tcx file, so it wasn't sent.")
            case .tooMany(let count): String(localized: "Too many files selected (\(count)): choose up to \(UploadPlan.maxFiles) at a time.")
            case .tooLarge(let name): String(localized: "\(name) is too large: at most \(UploadPlan.maxFileBytes >> 20) MB.")
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
                deleteIfInbox([url])
            } catch {
                notes.append(Note(text: String(localized: "\(name): the file couldn't be read"), error: true))
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

    /// Lists files another app opened here, to send on Upload.
    func share(_ urls: [URL]) {
        shared.add(urls)
        changed()
    }

    /// Upload's Upload: the listed files go.
    func sendShared() {
        enqueue(shared.take())
    }

    /// Upload's Cancel: the listed files are dropped.
    func cancelShared() {
        deleteIfInbox(shared.take())
        changed()
    }

    /// The session token ended: what it queued is cancelled, and its notes and listed files go,
    /// so nothing it picked is sent for, or shown to, the next account (apps/android/docs/SPEC.md
    /// FR-1.3). Only the tasks queued under token are cancelled: the session lists its tasks
    /// later, by when the next account may have queued its own.
    func drop(token: String) {
        endedTokens.insert(token)
        // The next account's imports are none of this one's.
        watching?.cancel()
        watching = nil
        watchGeneration += 1
        expected = 0
        session.getAllTasks { [endedTokens] tasks in
            for task in tasks where UploadTasks.ofEndedSession(task.originalRequest?.value(forHTTPHeaderField: "Authorization"), ended: endedTokens) {
                task.cancel()
            }
        }
        notes = []
        deleteIfInbox(shared.take())
        changed()
    }

    private func deleteIfInbox(_ urls: [URL]) {
        for url in urls where UploadTasks.isInboxCopy(url, inbox: inbox) { try? FileManager.default.removeItem(at: url) }
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
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            if error == nil, status == 426 { NotificationCenter.default.post(name: Self.outdated, object: nil) }
            guard !UploadTasks.ofEndedSession(task.originalRequest?.value(forHTTPHeaderField: "Authorization"), ended: endedTokens) else {
                changed()
                return
            }
            sentCount += 1
            switch APIClient.uploadOutcome(error: error, status: status, body: body) {
            case .sent: watch()
            case .unreachable: notes.append(Note(text: String(localized: "\(name): the server couldn't be reached"), error: true))
            case .already: notes.append(Note(text: String(localized: "\(name) was already uploaded before."), error: false))
            case .refused(let reason):
                notes.append(Note(text: String(localized: "\(name): \(reason.isEmpty ? String(localized: "the server refused it") : reason)"), error: true))
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

    /// An import this phone uploaded has ended: its track is in the account.
    static let landed = Notification.Name("Uploads.landed")

    /// Running at the last read of the imports, with the uploads accepted since (ImportWatch).
    private var expected = 0
    /// Uploads accepted, counted so a read knows which came while it was out.
    private var accepted = 0
    private var watching: Task<Void, Never>?
    /// Bumped when a watch starts or the session ends, so an old watch changes nothing.
    private var watchGeneration = 0

    /// An upload was accepted: the imports are read every few seconds until none runs, and each
    /// that ends is posted (landed). Failed reads wait longer each time, and give up
    /// (ImportWatch.delay); iOS holds the reads while the app is away, and they go on as it comes back.
    private func watch() {
        expected += 1
        accepted += 1
        guard watching == nil, let api else { return }
        watchGeneration += 1
        let mine = watchGeneration
        watching = Task { [weak self] in
            var failures = 0
            while let wait = ImportWatch.delay(failures: failures) {
                try? await Task.sleep(for: .seconds(wait))
                guard let before = self?.accepted, !Task.isCancelled else { return }
                guard let running = try? await api.activeImports().count else {
                    failures += 1
                    continue
                }
                guard let self, !Task.isCancelled, self.watchGeneration == mine else { return }
                failures = 0
                let step = ImportWatch.step(expected: self.expected, running: running, acceptedSince: self.accepted - before)
                self.expected = step.next
                if step.landed { NotificationCenter.default.post(name: Self.landed, object: nil) }
                if !step.again { break }
            }
            // Not a later watch's handle.
            if let self, self.watchGeneration == mine { self.watching = nil }
        }
    }

    /// A background upload's `426`: the app's flow shows the Update screen.
    static let outdated = Notification.Name("Uploads.outdated")
}