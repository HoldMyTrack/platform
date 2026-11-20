import Foundation

/// The tap on the notification posted as the app was swiped away while recording, held until the
/// signed-in screen can resume the recording: the tap may launch the app before anyone is signed
/// in, or reach one already up.
@MainActor
enum RecordingResume {
    static let asked = Notification.Name("RecordingResume.asked")
    private static var pending: String?

    /// The tap on the notification for recording id.
    static func ask(_ id: String) {
        pending = id
        NotificationCenter.default.post(name: asked, object: nil)
    }

    /// The recording a tap is waiting to resume, which this answers once.
    static func take() -> String? {
        defer { pending = nil }
        return pending
    }
}
