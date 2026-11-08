import Foundation

/// Where the map first frames an account (apps/android/docs/SPEC.md FR-2.3).
public enum MapFraming {
    /// The furthest the first framing zooms in.
    public static let maxZoom = 15.0

    /// The bounds `[west, south, east, north]` of the most recent activity with a track, skipping
    /// Pending ones, or nil when the account has nothing on the map.
    public static func latest(_ rows: [ActivityRow]) -> [Double]? {
        rows.filter { !$0.pending && ($0.bbox?.count ?? 0) == 4 && $0.startedAt != nil }
            .max { $0.startedAt! < $1.startedAt! }?.bbox
    }
}
