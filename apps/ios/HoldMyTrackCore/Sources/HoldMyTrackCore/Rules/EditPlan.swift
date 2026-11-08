/// The Edit window's decisions (root docs/SPEC.md FR-5.10, apps/android/docs/SPEC.md FR-2.7):
/// what it opens with, what it refuses, and which `PATCH /v1/activities/{id}` it sends.
public enum EditPlan {
    /// The server's bounds on each field.
    public static let maxType = 50
    public static let maxName = 200
    public static let maxDescription = 2000

    /// One PATCH: the full replace of the three fields.
    public struct Write: Equatable, Sendable {
        public let id: String
        public let activityType: String
        public let name: String
        public let description: String
    }

    public enum Invalid: Equatable, Sendable {
        case typeRequired
        case typeTooLong
        case nameTooLong
        case descriptionTooLong
    }

    /// The Type the window opens with: the group's one type, or empty for a group of mixed
    /// types, which keeps each its own unless one is picked.
    public static func initialType(_ group: [Activity]) -> String {
        guard let first = group.first?.activityType, group.allSatisfy({ $0.activityType == first }) else { return "" }
        return first
    }

    public static func invalid(group: [Activity], type: String, name: String, description: String) -> Invalid? {
        let type = type.trimmingCharacters(in: .whitespacesAndNewlines)
        if type.isEmpty && !initialType(group).isEmpty { return .typeRequired }
        if type.count > maxType { return .typeTooLong }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).count > maxName { return .nameTooLong }
        if description.count > maxDescription { return .descriptionTooLong }
        return nil
    }

    /// The writes Save sends, one activity at a time, for only what changed. One activity takes
    /// all three fields; a group only a picked type, each keeping its own name and description,
    /// and only the ones not of that type already.
    public static func writes(group: [Activity], type: String, name: String, description: String) -> [Write] {
        let type = type.trimmingCharacters(in: .whitespacesAndNewlines)
        if group.count == 1, let one = group.first {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let changed = type != one.activityType || name != (one.name ?? "") || description != (one.description ?? "")
            return changed ? [Write(id: one.id, activityType: type, name: name, description: description)] : []
        }
        guard !type.isEmpty else { return [] }
        return group.filter { $0.activityType != type }.map {
            Write(id: $0.id, activityType: type, name: $0.name ?? "", description: $0.description ?? "")
        }
    }
}