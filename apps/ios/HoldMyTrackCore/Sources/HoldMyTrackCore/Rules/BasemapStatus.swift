/// Whether the map says its basemap can't be reached (root docs/SPEC.md FR-4.4): a network that
/// throttles the tile host stalls its range reads instead of failing them, so the clock decides
/// as well as a failure (root docs/IMPLEMENTATION.md §5.4).
public enum BasemapStatus: String, Equatable, Sendable {
    case loading, loaded, unreachable

    /// How long the map waits on screen for a first basemap tile.
    public static let waitMs = 15_000

    public static func of(loaded: Bool, failed: Bool, waitedMs: Int) -> BasemapStatus {
        if loaded { return .loaded }
        if failed || waitedMs >= waitMs { return .unreachable }
        return .loading
    }
}
