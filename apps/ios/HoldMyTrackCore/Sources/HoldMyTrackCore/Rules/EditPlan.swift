/// The Edit window's decisions (root docs/SPEC.md FR-5.5, apps/android/docs/SPEC.md FR-2.7):
/// what it opens with, what it refuses, and which `PATCH /v2/tracks/{id}` it sends.
public enum EditPlan {
    /// The server's bounds on each field.
    public static let maxType = 50
    public static let maxName = 200
    public static let maxDescription = 2000

    /// One PATCH: the full replace of the three fields.
    public struct Write: Equatable, Sendable {
        public let id: String
        public let trackType: String
        public let name: String
        public let description: String

        /// Byte for byte, as the web and Android compare: Swift's == takes a composed and a
        /// decomposed accent as equal.
        func same(as other: Write) -> Bool {
            zip([id, trackType, name, description], [other.id, other.trackType, other.name, other.description]).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
        }
    }

    public enum Invalid: Equatable, Sendable {
        case typeRequired
        case typeTooLong
        case nameTooLong
        case descriptionTooLong
    }

    /// The Type the window opens with: the group's one type, or empty for a group of mixed
    /// types, which keeps each its own unless one is picked.
    public static func initialType(_ group: [Track]) -> String {
        guard let first = group.first?.trackType, group.allSatisfy({ $0.trackType == first }) else { return "" }
        return first
    }

    public static func invalid(group: [Track], type: String, name: String, description: String) -> Invalid? {
        let type = type.trimmingCharacters(in: .whitespacesAndNewlines)
        if type.isEmpty && !initialType(group).isEmpty { return .typeRequired }
        if type.unicodeScalars.count > maxType { return .typeTooLong }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count > maxName { return .nameTooLong }
        if description.unicodeScalars.count > maxDescription { return .descriptionTooLong }
        return nil
    }

    /// The writes Save sends, one track at a time, for each whose fields differ from what the
    /// server holds: what an earlier Save in this window wrote (written, by id), else what it opened
    /// with. One track takes all three fields; a group only a picked type, each keeping its own
    /// name and description. One whose last write failed (unsure) is written whatever it holds: the
    /// server may have taken it and the answer been lost. The cases are testdata/client-rules/edit-writes.json.
    public static func writes(group: [Track], type: String, name: String, description: String, written: [String: Write] = [:], unsure: Set<String> = []) -> [Write] {
        let type = type.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return group.compactMap { track in
            let held = written[track.id] ?? Write(id: track.id, trackType: track.trackType, name: track.name ?? "", description: track.description ?? "")
            let next = group.count == 1
                ? Write(id: track.id, trackType: type, name: name, description: description)
                : Write(id: track.id, trackType: type.isEmpty ? held.trackType : type, name: held.name, description: held.description)
            return next.same(as: held) && !unsure.contains(track.id) ? nil : next
        }
    }
}
