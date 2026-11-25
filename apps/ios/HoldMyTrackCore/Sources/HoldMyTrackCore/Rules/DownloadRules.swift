/// Whether Download (root docs/SPEC.md FR-17.2) can take its target, so it says why before a
/// request the server would refuse. The web's `apps/web/src/ui/downloadTarget.ts` and Android's
/// `panel/DownloadRules`; all three run testdata/client-rules/download-block.json.
public enum DownloadRules {
    /// The most tracks one download takes: Library's page size, and the server's cap.
    public static let maxTracks = 100

    public enum Block: Equatable, Sendable {
        case tooMany(count: Int)
        case pending(id: String)
        case `private`(id: String)
    }

    /// A track in the target, in order, with whether it is Pending and entirely inside Private
    /// locations.
    public struct Target: Equatable, Sendable {
        public let id: String
        public let pending: Bool
        public let isPrivate: Bool

        public init(id: String, pending: Bool, isPrivate: Bool) {
            self.id = id
            self.pending = pending
            self.isPrivate = isPrivate
        }
    }

    /// Why target can't be downloaded, or nil when it can: more than max tracks, else the first
    /// Pending one, else the first entirely inside Private locations. Checked in the panel can pass
    /// max while the map pans.
    public static func block(_ target: [Target], max: Int = maxTracks) -> Block? {
        if target.count > max { return .tooMany(count: target.count) }
        if let track = target.first(where: \.pending) { return .pending(id: track.id) }
        if let track = target.first(where: \.isPrivate) { return .private(id: track.id) }
        return nil
    }
}
