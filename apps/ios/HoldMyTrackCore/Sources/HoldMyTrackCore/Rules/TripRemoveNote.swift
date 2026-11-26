/// Where a track's failed removal is said in the Trips list: under the Trip it came from, folded
/// or not, since the failure can land after the Trip folded or another opened. Android's
/// TripsItems does the same.
public enum TripRemoveNote {
    public enum Place: Equatable, Sendable {
        /// Under the open Trip's numbers, above its rows.
        case afterStats
        /// Right under a folded or closed Trip's folder.
        case afterFolder
    }

    /// The place for the note under the Trip tripID, or nil when the failure is another Trip's
    /// or there is none.
    public static func place(tripID: String, expanded: Bool, failedTripID: String?) -> Place? {
        guard failedTripID == tripID else { return nil }
        return expanded ? .afterStats : .afterFolder
    }
}
