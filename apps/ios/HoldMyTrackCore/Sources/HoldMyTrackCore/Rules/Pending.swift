/// What a newly read list says about reprocesses: which started, which finished.
public struct PendingChange: Equatable, Sendable {
    /// The ids held Pending: the list's, and those it doesn't show that were.
    public let pending: Set<String>
    /// A row entered Pending.
    public let started: Bool
    /// A row left Pending, or an awaited edit landed.
    public let finished: Bool
    /// Ids that were pending and no longer are.
    public let left: Set<String>
    /// Awaited ids that landed with this list.
    public let landed: Set<String>
    /// Awaited ids not seen landing.
    public let awaiting: Set<String>
}

/// What the Pending check's answer says: moved means reading the list again, finished are the
/// watched ids the list doesn't show that are no longer Pending.
public struct PendingAnswer: Equatable, Sendable {
    public let moved: Bool
    public let finished: Set<String>
}

/// Trap: a job often finishes before the reload after a save answers, so its row is never seen
/// Pending. An edit saved here (awaiting) therefore also counts as finished the first time a
/// list shows it not pending.
///
/// Trap: the list is an area's, and a move of the map takes rows out of it. A missing row says
/// nothing about its reprocess, so a list speaks only for the rows it holds (listed), and the
/// Pending check answers for the rest (answer).
public enum PendingDiff {
    public static func of(previous: Set<String>, now: Set<String>, awaiting: Set<String>, listed: Set<String>) -> PendingChange {
        let done = { (id: String) in listed.contains(id) && !now.contains(id) }
        let left = previous.filter(done)
        let landed = awaiting.filter(done)
        return PendingChange(
            pending: now.union(previous.filter { !listed.contains($0) }),
            started: now.contains { !previous.contains($0) },
            finished: !left.isEmpty || !landed.isEmpty,
            left: left,
            landed: landed,
            awaiting: awaiting.subtracting(landed)
        )
    }

    /// The ids to ask the Pending check about: the rows held Pending and the edits saved here,
    /// once each, Pending first. Empty means there's nothing to watch.
    public static func watched(pending: [String], awaiting: [String]) -> [String] {
        var seen = Set<String>()
        return (pending + awaiting).filter { seen.insert($0).inserted }
    }

    /// The most ids one Pending check request may carry (`GET /v2/tracks/pending`).
    public static let batch = 200

    /// [ids] in consecutive batches of at most size, one Pending check request each; the answers
    /// are read as one. None for no ids.
    public static func batches(_ ids: [String], size: Int = batch) -> [[String]] {
        stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
    }

    /// What the Pending check's answer says about the watched ids no longer Pending: one the list
    /// holds means reading it again; one it doesn't has finished, since no list will say so.
    public static func answer(watched: [String], stillPending: [String], listed: Set<String>) -> PendingAnswer {
        let still = Set(stillPending)
        let done = watched.filter { !still.contains($0) }
        return PendingAnswer(moved: done.contains { listed.contains($0) }, finished: Set(done.filter { !listed.contains($0) }))
    }
}
