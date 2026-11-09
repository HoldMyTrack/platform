/// Whether Satellite imagery is loading on this device (root docs/SPEC.md FR-4.14): a network that
/// refuses or blocks the imagery host leaves Satellite with its fills hidden over nothing, so a
/// failure draws the map as with Satellite off while its layer stays on to notice a tile.
public enum SatelliteStatus: String, Equatable, Sendable {
    case loading, loaded, failed

    /// How long Satellite waits on screen for its first imagery tile.
    public static let waitMs = 15_000

    public static func of(loaded: Bool, failed: Bool, waitedMs: Int) -> SatelliteStatus {
        if loaded { return .loaded }
        if failed || waitedMs >= waitMs { return .failed }
        return .loading
    }

    /// Whether the map looks like Satellite: its fills hidden and its roads dimmed.
    public static func look(on: Bool, status: SatelliteStatus) -> Bool { on && status != .failed }
}
