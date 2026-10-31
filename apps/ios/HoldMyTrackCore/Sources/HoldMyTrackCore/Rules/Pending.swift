/// What a newly read list says about reprocesses: which started, which finished.
public struct PendingChange: Equatable, Sendable {
    /// The ids pending now.
    public let now: Set<String>
    /// A row entered Pending.
    public let started: Bool
    /// A row left Pending, or an awaited edit landed.
    public let finished: Bool
    /// Ids that were pending and no longer are.
    public let left: Set<String>
    /// Awaited ids that landed with this list.
    public let landed: Set<String>
    /// Awaited ids still pending.
    public let awaiting: Set<String>
}

/// Trap: a job often finishes before the reload after a save answers, so its row is never seen
/// Pending. An edit saved here (awaiting) therefore also counts as finished the first time a
/// list shows it not pending.
public enum PendingDiff {
    public static func of(previous: Set<String>, now: Set<String>, awaiting: Set<String>) -> PendingChange {
        let left = previous.subtracting(now)
        let landed = awaiting.subtracting(now)
        return PendingChange(
            now: now,
            started: now.contains { !previous.contains($0) },
            finished: !left.isEmpty || !landed.isEmpty,
            left: left,
            landed: landed,
            awaiting: awaiting.intersection(now)
        )
    }

    /// The ids to ask the Pending check about: the rows the list shows Pending and the edits
    /// saved here, once each, listed first. Empty means there's nothing to watch.
    public static func watched(listed: [String], awaiting: [String]) -> [String] {
        var seen = Set<String>()
        return (listed + awaiting).filter { seen.insert($0).inserted }
    }

    /// The most ids one Pending check request may carry (`GET /v1/activities/pending`).
    public static let batch = 200

    /// [ids] in consecutive batches of at most size, one Pending check request each; the answers
    /// are read as one. None for no ids.
    public static func batches(_ ids: [String], size: Int = batch) -> [[String]] {
        stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
    }

    /// Whether the Pending check's answer means the list should be read again: one of the
    /// watched ids is no longer Pending.
    public static func moved(watched: [String], stillPending: [String]) -> Bool {
        let pending = Set(stillPending)
        return watched.contains { !pending.contains($0) }
    }
}
