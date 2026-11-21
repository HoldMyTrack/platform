/// What the controls over the map show, beside the modes (apps/android/docs/SPEC.md FR-2.2).
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

    /// The Layers button: Roads and each path picked; places have their own button.
    public static func layers(_ state: MapState) -> RailLook {
        let picked = (state.roads ? 1 : 0) + state.toggles.filter { $0.key != Spots.group && $0.value }.count
        return .of(picked: picked, shown: state.showLayers)
    }

    /// The Places button: each category picked.
    public static func places(_ state: MapState, picked: Int) -> RailLook {
        .of(picked: picked, shown: state.showPlaces)
    }
}
