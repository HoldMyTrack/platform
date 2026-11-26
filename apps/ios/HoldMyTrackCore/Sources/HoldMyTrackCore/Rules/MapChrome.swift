/// What the controls over the map show, beside the modes (apps/docs/SPEC.md FR-2.2).
public enum MapChrome {
    /// A rail button with a menu of picks under a show-or-hide switch, Layers or Places: filled
    /// while picks show, a badge counting them, greyed while the switch hides them, and the
    /// switch disabled with nothing picked. Android's `RailLook`.
    public struct RailLook: Equatable, Sendable {
        public let count: Int
        public let filled: Bool
        public let badge: Bool
        public let greyed: Bool
        public let switchEnabled: Bool

        public static func of(picked: Int, shown: Bool) -> RailLook {
            RailLook(count: picked, filled: shown && picked > 0, badge: picked > 0, greyed: !shown, switchEnabled: picked > 0)
        }
    }

    /// The empty notice tells a real account with nothing on the map how to add something, until
    /// this phone closes it for the account. The demo account has history and adds nothing.
    public static func emptyNoticeShown(empty: Bool, demo: Bool, closed: Bool) -> Bool {
        empty && !demo && !closed
    }

    /// Whether the map draws the routes through the Tracks tab's filters: not on Library or its
    /// Sync, where it shows every track (testdata/client-rules/map-tracks-filters.json).
    public static func tracksFiltersApply(onLibrary: Bool) -> Bool { !onLibrary }

    /// Whether the empty and capped notices show: they step aside while recording and on Library
    /// and its Sync, whose lists aren't the area's; failures stay up.
    public static func areaNoticesShown(recording: Bool, onLibrary: Bool) -> Bool { !recording && !onLibrary }

    /// The Layers button: Roads and each path picked; places have their own button.
    public static func layers(_ state: MapState) -> RailLook {
        let picked = (state.roads ? 1 : 0) + state.toggles.filter { $0.key != Spots.group && $0.value }.count
        return .of(picked: picked, shown: state.showLayers)
    }

    /// Whether rows are checked where the selection bar can show: the sheet up on the Tracks tab,
    /// no Edit window.
    public static func selectionShown(sheetVisible: Bool, selecting: Bool, onTracksTab: Bool, editOpen: Bool) -> Bool {
        sheetVisible && selecting && onTracksTab && !editOpen
    }

    /// The mode toggle: the Tracks tab's, hidden while recording, editing or checking rows; the
    /// recording's status or the selection bar take its place.
    public static func modeBarShown(recording: Bool, editOpen: Bool, selectionShown: Bool, onTracksTab: Bool) -> Bool {
        onTracksTab && !recording && !editOpen && !selectionShown
    }

    /// The sheet: Normal mode's, and Library's and its Sync's even while recording, so what's on
    /// the phone can be sent mid-walk; hidden while the Edit window or the Private location editor
    /// is open, so the map above the Edit sheet stays clear.
    public static func sheetShown(normal: Bool, recording: Bool, onLibrary: Bool, editing: Bool) -> Bool {
        normal && (!recording || onLibrary) && !editing
    }

    /// A flight a list or Dates asked for, taken unless a recording is live: the recording owns the
    /// camera, and its next fix would pan straight back. The caller consumes the ask either way,
    /// so Stop doesn't fly to it later.
    public static func flies(asked: Bool, recording: Bool) -> Bool { asked && !recording }

    /// The list follows a settled camera unless the app moved it (a focused row, a Trip) or a
    /// recording is live, whose camera moves with every fix.
    public static func listFollows(appFlight: Bool, recording: Bool) -> Bool { !appFlight && !recording }

    /// The rail, hidden while an editor has the map or rows are checked.
    public static func railShown(editing: Bool, selectionShown: Bool) -> Bool { !editing && !selectionShown }

    /// The export's own button under the selection bar, while rows are checked and the rail is
    /// away, so an image can show the checked tracks' stats.
    public static func checkedExportShown(editing: Bool, selectionShown: Bool, recording: Bool) -> Bool {
        !editing && selectionShown && !recording
    }

    /// The tab bar and the record button, gone while the Edit window, the Private location editor
    /// or the image export has the screen: a tab or a recording would start under it.
    public static func bottomBarShown(editOpen: Bool, privacyEditing: Bool, exportOpen: Bool) -> Bool {
        !editOpen && !privacyEditing && !exportOpen
    }

    /// Whether a tap on tapped's button while current is on opens Fog's level menu: a tap on Fog
    /// while it's on.
    public static func fogMenuOnTap(tapped: MapMode, current: MapMode) -> Bool { tapped == .fog && current == .fog }

    /// The Places button: each category picked.
    public static func places(_ state: MapState, picked: Int) -> RailLook {
        .of(picked: picked, shown: state.showPlaces)
    }

    /// Where the base map's credit sits (root docs/IMPLEMENTATION.md §5.6): above the collapsed
    /// sheet while the sheet shows, whatever its detent (apps/docs/SPEC.md FR-2.4), else at
    /// the bottom; the mark at the start and the credit's button after it. Offsets are from the
    /// safe area's bottom and start.
    public struct CreditPlace: Equatable, Sendable {
        public let logoX: Double
        public let buttonX: Double
        public let lift: Double
    }

    public static func credit(sheetShown: Bool, collapsedSheet: Double, logoWidth: Double, gap: Double, space: Double) -> CreditPlace {
        CreditPlace(logoX: gap, buttonX: gap + logoWidth + space, lift: (sheetShown ? collapsedSheet : 0) + gap)
    }

    /// What came back when the map's documents didn't, for the small print under "The map couldn't
    /// load.": the app words each kind in the user's language, as Android shows its origin and
    /// MapLibre's error.
    public enum LoadFailure: Equatable, Sendable {
        case status(Int, message: String?)
        case noAnswer
        case unreadable
    }

    public static func loadFailure(_ error: APIError) -> LoadFailure {
        switch error {
        case .http(let status, _, let message): .status(status, message: message.flatMap { $0.isEmpty ? nil : $0 })
        case .outdated: .status(426, message: nil)
        case .unreachable: .noAnswer
        case .unreadable: .unreadable
        }
    }
}
