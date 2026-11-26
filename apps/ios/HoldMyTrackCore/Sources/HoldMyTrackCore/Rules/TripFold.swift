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

/// What a Trips list answer means on the Trips tab (testdata/client-rules/trip-list-answer.json).
public enum TripsList {
    /// On a return (quiet), an open Trip missing from listed was deleted elsewhere.
    public static func openGone(quiet: Bool, open: String?, listed: Set<String>, failed: Bool) -> Bool {
        guard !failed, quiet, let open else { return false }
        return !listed.contains(open)
    }

    /// A failed read says so when nothing is shown yet, or when the tab asked itself.
    public static func showsError(quiet: Bool, ready: Bool, failed: Bool) -> Bool { failed && (!quiet || !ready) }
}

/// Where the open Trip's numbers go on the Trips tab: pinned under the list, as Android's footer,
/// unless that leaves the rows too little room, as in landscape, at the half sheet with many types
/// or at large text; then the list's footer, scrolled to.
public enum TripStatsPlace {
    /// height: the numbers' at the tab's width; available: the tab's content height.
    public static func pinned(compactHeight: Bool, height: Double, available: Double) -> Bool {
        !compactHeight && height <= available * 0.4
    }
}
