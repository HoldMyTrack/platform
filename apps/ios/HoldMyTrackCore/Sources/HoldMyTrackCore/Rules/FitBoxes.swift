/// The boxes a camera fit over several tracks frames, in their order (root docs/SPEC.md FR-5.8,
/// the `fitBoxes` rule): the opening view, the Dates flight and a Trip's list flight. A Pending
/// track is left out, and so is a Private one, whose bbox is its location's circle: only focusing
/// that row flies there.
public enum FitBoxes {
    public static func of(_ tracks: [Track]) -> [[Double]] {
        tracks.filter { !$0.pending && !$0.isPrivate }.compactMap(\.bbox)
    }

    /// What Show on map frames (the `selectionBoxes` rule): one track's own bbox, a Private one's
    /// circle included; several, `of`'s, so a circle never joins other tracks' routes.
    public static func selection(_ tracks: [Track]) -> [[Double]] {
        tracks.count == 1 ? tracks.compactMap(\.bbox) : of(tracks)
    }
}