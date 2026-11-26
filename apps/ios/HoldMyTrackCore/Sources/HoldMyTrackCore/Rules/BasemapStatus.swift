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

    /// Whether a new style's basemap source differs from the one being watched, so the clock
    /// starts again. A reload that keeps the source keeps its tiles and reports no tile action
    /// that would mark them loaded again.
    public static func sourceChanged(from old: JSONValue?, to new: JSONValue) -> Bool {
        old?["sources"]?[ExportStyle.basemapSource] != new["sources"]?[ExportStyle.basemapSource]
    }
}
