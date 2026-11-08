import Foundation

/// Where the map first frames an account (apps/android/docs/SPEC.md FR-2.3).
public enum MapFraming {
    /// The furthest the first framing zooms in.
    public static let maxZoom = 15.0

    /// The smallest box `[west, south, east, north]` holding every box, the short way round:
    /// across the antimeridian east passes 180 (Android's BoxUnion).
    public static func union(_ boxes: [[Double]]) -> [Double]? {
        guard !boxes.isEmpty else { return nil }
        let arcs = boxes.map { b -> (Double, Double) in
            let shift = 360 * ((b[0] + 180) / 360).rounded(.down)
            return (b[0] - shift, b[2] - shift)
        }
        var best = (-180.0, 180.0)
        for (start, _) in arcs {
            var end = start
            for (west, east) in arcs { end = max(end, west < start ? east + 360 : east) }
            if end - start < best.1 - best.0 { best = (start, end) }
        }
        return [best.0, boxes.map { $0[1] }.min()!, best.1, boxes.map { $0[3] }.max()!]
    }

    /// The tiles' query for the tracks of range (root docs/SPEC.md FR-14.4's filter, by date).
    public static func tracksQuery(_ range: DateRange?) -> String {
        guard let range else { return "" }
        return "from=\(range.from)&to=\(range.to)"
    }

    /// The bounds `[west, south, east, north]` of the most recent activity with a track, skipping
    /// Pending ones, or nil when the account has nothing on the map.
    public static func latest(_ rows: [ActivityRow]) -> [Double]? {
        rows.filter { !$0.pending && ($0.bbox?.count ?? 0) == 4 && $0.startedAt != nil }
            .max { $0.startedAt! < $1.startedAt! }?.bbox
    }
}
