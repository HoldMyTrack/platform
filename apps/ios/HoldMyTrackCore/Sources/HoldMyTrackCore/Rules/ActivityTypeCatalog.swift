/// What the app shows for each activity type, as the server says (root docs/SPEC.md FR-5.1,
/// `GET /v1/activity-types`, every activity list's `types` and every Story's labels): its label
/// and its kind. The app matches no words and keeps no catalog of its own; a type the server
/// hasn't described is `.other`, its label spaced out from snake_case and title-cased, as the
/// server falls back.
public struct ActivityTypeCatalog: Equatable, Sendable {
    public private(set) var kinds: [String: ActivityKind] = [:]
    public private(set) var labels: [String: String] = [:]

    public init() {}

    public func kind(_ type: String) -> ActivityKind { kinds[type] ?? .other }

    public func label(_ type: String) -> String { labels[type] ?? Self.fallbackLabel(type) }

    /// The server's own fallback for a type with no name of its own.
    public static func fallbackLabel(_ type: String) -> String {
        type.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// What a response said about its types; true when anything changed.
    @discardableResult
    public mutating func merge(_ described: [String: ActivityTypeInfo]) -> Bool {
        var changed = false
        for (type, info) in described {
            if let kind = info.kind, kinds[type] != kind {
                kinds[type] = kind
                changed = true
            }
            if let label = info.label, labels[type] != label {
                labels[type] = label
                changed = true
            }
        }
        return changed
    }

    /// The types among types that have no label yet, at most limit (the server's bound on named
    /// types), each once.
    public func missing(_ types: [String], limit: Int = 100) -> [String] {
        var seen = Set<String>()
        return Array(types.filter { !$0.isEmpty && labels[$0] == nil && seen.insert($0).inserted }.prefix(limit))
    }
}