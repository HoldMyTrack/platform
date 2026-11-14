/// What the controls over the map show, beside the modes (apps/android/docs/SPEC.md FR-2.2).
public enum MapChrome {
    /// The chip naming what Fog shows, since it doesn't take the date range.
    public enum Chip: Equatable, Sendable { case everyActivity }

    public static func chip(_ mode: MapMode) -> Chip? {
        switch mode {
        case .normal: nil
        case .fog: .everyActivity
        }
    }

    /// The Layers button: filled while picks show, with a badge counting Roads, the paths and the
    /// places picked, greyed while Show layers hides them.
    public struct LayersBadge: Equatable, Sendable {
        public let count: Int
        public let filled: Bool
        public let greyed: Bool
    }

    public static func layersBadge(_ state: MapState, places: Int) -> LayersBadge {
        let count = (state.roads ? 1 : 0) + state.toggles.filter { $0.key != Spots.group && $0.value }.count + places
        return LayersBadge(count: count, filled: state.showLayers && count > 0, greyed: !state.showLayers)
    }
}
