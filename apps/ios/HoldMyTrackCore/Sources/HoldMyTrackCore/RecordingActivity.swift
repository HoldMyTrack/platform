import Foundation

/// What the recording's Live Activity shows (apps/ios/docs/SPEC.md FR-5.1), as values the app
/// works out and the widget extension draws: the extension has none of the app's state, formats
/// or strings, so every word comes in already written.
public struct RecordingActivityState: Codable, Hashable, Sendable {
    public let paused: Bool
    /// The clock: counting from this moment while recording, so the system ticks it with no update.
    public let clockStart: Date
    /// The moving time written out, for while it's paused and the clock stands still.
    public let clock: String
    public let distance: String
    /// "Recording" or "Paused", "Pause" or "Resume", and "Stop", in the app's language.
    public let title: String
    public let toggle: String
    public let stop: String

    public init(paused: Bool, clockStart: Date, clock: String, distance: String, title: String, toggle: String, stop: String) {
        self.paused = paused
        self.clockStart = clockStart
        self.clock = clock
        self.distance = distance
        self.title = title
        self.toggle = toggle
        self.stop = stop
    }

    /// The moment a clock showing moving would have started, counted from now.
    public static func clockStart(moving: TimeInterval, at now: Date) -> Date { now.addingTimeInterval(-moving) }
}

/// Where the Live Activity's Stop goes: the app opens on it and asks before stopping.
public enum RecordingLink {
    public static let stop = URL(string: "holdmytrack://recording/stop")!

    public static func isStop(_ url: URL) -> Bool { url.scheme == stop.scheme && url.host == stop.host && url.path == stop.path }
}

#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import AppIntents

/// The recording's Live Activity: one per recording, its state the only thing that changes.
public struct RecordingActivityAttributes: ActivityAttributes {
    public typealias ContentState = RecordingActivityState
    public init() {}
}

/// The Live Activity's Pause or Resume, run in the app's process, which hands it to the recording.
public struct ToggleRecordingIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Pause or resume the recording"
    /// Set by the app; the extension, which only shows the button, never runs the intent.
    @MainActor public static var perform: (() -> Void)?

    public init() {}

    public func perform() async throws -> some IntentResult {
        await MainActor.run { Self.perform?() }
        return .result()
    }
}
#endif