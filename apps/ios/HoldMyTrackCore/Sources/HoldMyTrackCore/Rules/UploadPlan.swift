import Foundation

/// Which of a set of picked files Upload sends, and why the others don't: the web upload's
/// checks against the server's limits (root docs/SPEC.md FR-3.1), so a file it would refuse isn't
/// sent first. The shared `uploadPlan` rule.
public struct UploadPlan: Equatable, Sendable {
    public enum Refusal: Equatable, Sendable {
        /// An archive: not imported (ADR-0039).
        case zip(String)
        /// Not a `.gpx`, `.fit` or `.tcx`.
        case wrongType(String)
        /// More than maxFiles activity files at once: none of them is sent.
        case tooMany(Int)
        /// Past the server's size limit.
        case tooLarge(String)
    }

    /// A picked file as the checks need it; size is -1 when the provider doesn't say.
    public struct Picked: Equatable, Sendable {
        public let name: String
        public let size: Int

        public init(name: String, size: Int) {
            self.name = name
            self.size = size
        }
    }

    /// Indexes into the picked files, in their order.
    public let send: [Int]
    /// Wrong kinds first, then too many, then each too large.
    public let refusals: [Refusal]

    /// The web's cap on files picked at once.
    public static let maxFiles = 20
    /// The server's limit on one file.
    public static let maxFileBytes = 16 << 20
    /// The kinds the app opens, by extension.
    public static let extensions = ["gpx", "fit", "tcx"]

    public static func of(_ picked: [Picked]) -> UploadPlan {
        func ext(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }
        var refusals: [Refusal] = []
        for file in picked where !extensions.contains(ext(file.name)) {
            refusals.append(ext(file.name) == "zip" ? .zip(file.name) : .wrongType(file.name))
        }
        var activityFiles = picked.indices.filter { extensions.contains(ext(picked[$0].name)) }
        if activityFiles.count > maxFiles {
            refusals.append(.tooMany(activityFiles.count))
            activityFiles = []
        }
        var send: [Int] = []
        for i in activityFiles {
            if picked[i].size > maxFileBytes { refusals.append(.tooLarge(picked[i].name)) } else { send.append(i) }
        }
        return UploadPlan(send: send, refusals: refusals)
    }
}