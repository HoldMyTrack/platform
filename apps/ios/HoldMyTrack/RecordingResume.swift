import Foundation

/// The tap on the notification posted as the app was swiped away while recording, held until the
/// signed-in screen can resume the recording: the tap may launch the app before anyone is signed
/// in, or reach one already up.
@MainActor
enum RecordingResume {
    static let asked = Notification.Name("RecordingResume.asked")
    private static var pending = false

    static func ask() {
        pending = true
        NotificationCenter.default.post(name: asked, object: nil)
    }

    /// Whether a tap is waiting, which this answers once.
    static func take() -> Bool {
        defer { pending = false }
        return pending
    }
}
