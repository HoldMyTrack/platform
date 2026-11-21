import Foundation

/// The Type picker's list and search (root docs/SPEC.md FR-5.5): `track_type` is free text, so the
/// picker lists the types in use, filters them as the user types, and offers what was typed as a
/// new type. The search is a shared rule (testdata/client-rules/type-search.json).
public enum TypeSearch {
    /// A row: the raw `track_type`, its label, and how many tracks use it (0 shows none).
    public struct Option: Equatable, Sendable {
        public let value: String
        public let label: String
        public let count: Int

        public init(value: String, label: String, count: Int) {
            self.value = value
            self.label = label
            self.count = count
        }
    }

    /// What a search shows: the matching options, and the text offered as a new type, if any.
    public struct Result: Equatable, Sendable {
        public let shown: [Option]
        public let add: String?
    }

    /// A blank query lists options as given. Otherwise an exact label comes first, then a label or
    /// one of its words starting with the query, then a label or raw value containing it, keeping
    /// options' order within each rank; the trimmed query is offered as add while no option's
    /// label or value equals it and it fits maxLength.
    public static func search(_ options: [Option], query: String, maxLength: Int) -> Result {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return Result(shown: options, add: nil) }
        let q = fold(text)
        var ranked: [[Option]] = [[], [], []]
        for o in options {
            let label = fold(o.label)
            if label == q {
                ranked[0].append(o)
            } else if label.hasPrefix(q) || label.contains(" " + q) {
                ranked[1].append(o)
            } else if label.contains(q) || fold(o.value).contains(q) {
                ranked[2].append(o)
            }
        }
        let exact = options.contains { fold($0.value) == q || fold($0.label) == q }
        return Result(shown: ranked.flatMap { $0 }, add: !exact && text.unicodeScalars.count <= maxLength ? text : nil)
    }

    /// Case- and accent-insensitive: every nonspacing mark goes, as on the web and Android.
    static func fold(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: s.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars.filter { $0.properties.generalCategory != .nonspacingMark })
        return String(scalars)
    }

    /// The rows for known (type and count, in order), led by current when none of them is it, so
    /// the current choice is always there to see. An empty current (a mixed group) adds nothing.
    public static func options(current: String, known: [(type: String, count: Int)], label: (String) -> String) -> [Option] {
        var rows = known.map { Option(value: $0.type, label: label($0.type), count: $0.count) }
        if !current.isEmpty, !known.contains(where: { $0.type == current }) {
            rows.insert(Option(value: current, label: label(current), count: 0), at: 0)
        }
        return rows
    }

    /// Listed for a recording even on an account that never used them, so most recordings keep to
    /// the types a `.FIT` upload gets.
    public static let recordingPresets = ["walking", "hiking", "running", "cycling", "driving"]

    /// A recording's Type list (testdata/client-rules/recording-types.json): the account's types
    /// (server, in the order its rows first use them; empty when it couldn't be read) and those of
    /// this phone's recordings waiting to be sent (local) counted together, most used first with ties
    /// in first appearance; then any preset not among them. `unknown`, the placeholder for no type,
    /// is left out.
    public static func recordingKnown(server: [(type: String, count: Int)], local: [String]) -> [(type: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        func add(_ type: String, _ n: Int) {
            if counts[type] == nil { order.append(type) }
            counts[type, default: 0] += n
        }
        for (type, count) in server { add(type, count) }
        for type in local { add(type, 1) }
        let used = order.enumerated().filter { $0.element != "unknown" }
            .sorted { (counts[$0.element]!, $1.offset) > (counts[$1.element]!, $0.offset) }
            .map { (type: $0.element, count: counts[$0.element]!) }
        return used + recordingPresets.filter { counts[$0] == nil }.map { (type: $0, count: 0) }
    }
}