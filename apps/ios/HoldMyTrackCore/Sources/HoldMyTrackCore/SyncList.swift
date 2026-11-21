import Foundation

/// What the Sync tab lists and offers, as values (apps/android/docs/SPEC.md FR-3.2, FR-3.5).
/// A recording sent and not landed yet is listed as on its way: never tickable, hidden or edited.
/// One in the send running now (inFlight) is neither ticked, edited nor deleted, and no row is
/// swiped while a send runs. The demo account ticks nothing.
public struct SyncList: Equatable, Sendable {
    /// Every recording, hidden or not, on its way or not, newest first.
    public let everything: [RecordedTrack]
    /// What the list shows: hidden rows only with Show hidden, and only the chosen types.
    public let shown: [RecordedTrack]
    /// What Select all and the count offer: shown, not hidden, not on its way, not being sent.
    public let tickable: [RecordedTrack]
    /// What Sync sends: tickable and ticked.
    public let sendable: [RecordedTrack]
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
    public static func of(_ recordings: [RecordedTrack], hidden: Set<String>, showHidden: Bool, types: Set<String>, ticked: Set<String>,
                          isDemo: Bool = false, inFlight: Set<String> = []) -> SyncList {
        let everything = recordings.sorted { $0.startedAt > $1.startedAt }
        let listedTypes = Array(Set(everything.map(\.type))).sorted()
        let picked = types.intersection(listedTypes)
        let shown = everything.filter { (showHidden || !hidden.contains($0.id)) && (picked.isEmpty || picked.contains($0.type)) }
        let tickable = isDemo ? [] : shown.filter { !hidden.contains($0.id) && !$0.sent && !inFlight.contains($0.id) }
        return SyncList(
            everything: everything,
            shown: shown,
            tickable: tickable,
            sendable: tickable.filter { ticked.contains($0.id) },
            types: listedTypes,
            hiddenCount: everything.filter { hidden.contains($0.id) }.count,
            inFlight: inFlight,
            comparable: shown.filter { !hidden.contains($0.id) && !$0.sent && !inFlight.contains($0.id) }
        )
    }

    /// Whether a row's tick can be changed.
    public func canTick(_ track: RecordedTrack) -> Bool { tickable.contains { $0.id == track.id } }

    /// Edit and Delete: a recording still on the phone and not being sent.
    public func canEdit(_ track: RecordedTrack) -> Bool { !track.sent && !inFlight.contains(track.id) }

    /// A swipe hides a row, or brings a hidden one back: not one on its way, nor while a send runs.
    public func canSwipe(_ track: RecordedTrack) -> Bool { !track.sent && inFlight.isEmpty }

    /// Whether Select all reads Select none: there's something to tick and all of it is.
    public func allTicked(_ ticked: Set<String>) -> Bool {
        !tickable.isEmpty && tickable.allSatisfy { ticked.contains($0.id) }
    }

    /// Select all, or Select none when everything tickable is ticked already.
    public func toggleAll(_ ticked: Set<String>) -> Set<String> {
        let ids = Set(tickable.map(\.id))
        return allTicked(ticked) ? ticked.subtracting(ids) : ticked.union(ids)
    }

    /// The distance Sync would send.
    public var sendableMeters: Double { sendable.reduce(0) { $0 + $1.meters } }

    /// The chips picked that are still listed.
    public func pickedTypes(_ types: Set<String>) -> Set<String> { types.intersection(self.types) }
}

/// The phone's hidden Sync rows (apps/android/docs/SPEC.md FR-3.5): recordings swiped aside, by
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