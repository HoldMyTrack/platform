import Foundation

/// What the Sync tab lists and offers, as values (apps/docs/SPEC.md FR-3.2, FR-3.5).
/// Every row is a recording, which sends itself (RecordingSends), so none is ticked. One sent and
/// not landed yet, or in the send running now (inFlight), is neither swiped, edited nor deleted.
public struct SyncList: Equatable, Sendable {
    /// Every recording, hidden or not, on its way or not, newest first.
    public let everything: [RecordedTrack]
    /// What the list shows: hidden rows only with Show hidden, and only the chosen types.
    public let shown: [RecordedTrack]
    /// The types listed, one chip each when there's more than one.
    public let types: [String]
    /// How many rows are hidden, for Show hidden's count.
    public let hiddenCount: Int
    /// The recordings the running send is sending.
    public let inFlight: Set<String>
    /// What the map draws: shown, not on its way.
    public var drawn: [RecordedTrack] { shown.filter { !$0.sent } }
    /// What another row can be a double of: shown, not hidden, not on its way, not being sent, so
    /// the similar-tracks hint never names a row the list doesn't show.
    public let comparable: [RecordedTrack]

    /// The list for recordings under the tab's choices. types is the chips picked; empty is
    /// every type. A type no longer listed is dropped from it (`pickedTypes`).
    public static func of(_ recordings: [RecordedTrack], hidden: Set<String>, showHidden: Bool, types: Set<String>,
                          inFlight: Set<String> = []) -> SyncList {
        let everything = recordings.sorted { $0.startedAt > $1.startedAt }
        let listedTypes = Array(Set(everything.map(\.type))).sorted()
        let picked = types.intersection(listedTypes)
        let shown = everything.filter { (showHidden || !hidden.contains($0.id)) && (picked.isEmpty || picked.contains($0.type)) }
        return SyncList(
            everything: everything,
            shown: shown,
            types: listedTypes,
            hiddenCount: everything.filter { hidden.contains($0.id) }.count,
            inFlight: inFlight,
            comparable: shown.filter { !hidden.contains($0.id) && !$0.sent && !inFlight.contains($0.id) }
        )
    }

    /// Edit and Delete: a recording still on the phone and not being sent.
    public func canEdit(_ track: RecordedTrack) -> Bool { !track.sent && !inFlight.contains(track.id) }

    /// A swipe hides a row, or brings a hidden one back: not one on its way or being sent.
    public func canSwipe(_ track: RecordedTrack) -> Bool { canEdit(track) }

    /// The chips picked that are still listed.
    public func pickedTypes(_ types: Set<String>) -> Set<String> { types.intersection(self.types) }
}

/// The phone's hidden Sync rows (apps/docs/SPEC.md FR-3.5): recordings swiped aside, by
/// id, kept by RecordingStore.
public enum SyncHidden {
    /// A swipe: hidden, or a hidden row back on the list.
    public static func swiped(_ id: String, in hidden: Set<String>) -> Set<String> {
        setting(id, hidden: !hidden.contains(id), in: hidden)
    }

    /// id hidden or not, whatever it is now: Undo puts back what a swipe changed.
    public static func setting(_ id: String, hidden isHidden: Bool, in hidden: Set<String>) -> Set<String> {
        isHidden ? hidden.union([id]) : hidden.subtracting([id])
    }
}