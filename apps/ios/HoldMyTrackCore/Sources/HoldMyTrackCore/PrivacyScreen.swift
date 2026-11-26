import Foundation

/// What the Privacy screen offers and says (apps/docs/SPEC.md FR-1.7). The demo account
/// sees its Private locations read-only: no Add, and no download, its data being deleted within
/// the day.
public enum PrivacyScreen {
    public static func offersAdd(demo: Bool) -> Bool { !demo }
    public static func offersDownload(demo: Bool) -> Bool { !demo }

    /// The lines under the locations: how many tracks they hide entirely, once the server has
    /// said (nil leaves it out), and, for an account that can change them, that a change
    /// reprocesses. None without locations.
    public struct Footer: Equatable, Sendable {
        public let hidden: Int?
        public let reprocess: Bool
    }

    public static func footer(locations: Int, hidden: Int?, demo: Bool) -> Footer? {
        guard locations > 0, hidden != nil || !demo else { return nil }
        return Footer(hidden: hidden, reprocess: !demo)
    }
}

/// What Download your data says for each state of the export (root docs/SPEC.md FR-1.13), as
/// Android's DataExportActivity.
public enum DataExportText {
    public enum Status: Equatable, Sendable {
        /// Nothing requested: no line.
        case none
        case preparing
        /// Ready: the parts' total, and until when, nil when the server's date can't be read.
        case ready(totalBytes: Int, until: Date?)
        case failed
    }

    public static func status(_ export: ExportStatus) -> Status {
        switch export.state {
        case .none: .none
        case .preparing: .preparing
        case .ready: .ready(totalBytes: export.parts.reduce(0) { $0 + $1.size }, until: export.expiresAt.flatMap(date))
        case .failed: .failed
        }
    }

    /// Request a new one once an archive is ready; else Request a download. None while preparing.
    public static func offersRequest(_ state: ExportStatus.State) -> Bool { state != .preparing }
    public static func requestsAgain(_ state: ExportStatus.State) -> Bool { state == .ready }

    /// An ISO 8601 moment, with fractional seconds as the server writes them or without.
    public static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
