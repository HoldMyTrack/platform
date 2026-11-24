/// Folding the open Trip on the Trips tab (root docs/SPEC.md FR-13.6), the web's
/// `apps/web/src/ui/tripFold.ts` (`testdata/client-rules/trip-fold.json`): a tap on the open Trip's
/// folder hides or shows its list and changes nothing else, so it stays open with the map and
/// totals narrowed to it. A tap on another folder opens that one unfolded.
public enum TripFold {
    /// `foldedID`: the Trip whose list is folded after the tap; `open`: the tapped Trip is another
    /// one, to open.
    public struct Click: Equatable, Sendable {
        public let foldedID: String?
        public let open: Bool
    }

    public static func folderClick(foldedID: String?, openID: String?, clickedID: String) -> Click {
        if clickedID != openID { return Click(foldedID: nil, open: true) }
        return Click(foldedID: foldedID == clickedID ? nil : clickedID, open: false)
    }

    /// Whether the open Trip's list is hidden; a fold left on another Trip counts for nothing.
    public static func isFolded(foldedID: String?, openID: String?) -> Bool {
        openID != nil && foldedID == openID
    }
}
