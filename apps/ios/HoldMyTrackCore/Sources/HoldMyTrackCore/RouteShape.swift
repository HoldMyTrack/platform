import Foundation

/// Douglas–Peucker over a route, in metres: the points a line drawn on the map needs, not the
/// one-a-second thousands a phone records. For drawing only: what is sent is always the route as
/// recorded. Distances are on a local equirectangular plane around the first point, close enough
/// over one track's extent. Android's Simplify.
public enum Simplify {
    /// Under this from the line between its neighbours' kept points, a point is dropped.
    public static let toleranceM = 15.0
    /// At most this many points come back: past it, the tolerance doubles until they fit.
    public static let maxPoints = 500

    /// The indexes of the points to keep, first and last always among them.
    public static func indexes(lats: [Double], lons: [Double], toleranceM: Double = toleranceM, maxPoints: Int = maxPoints) -> [Int] {
        let n = lats.count
        if n <= 2 { return Array(0..<n) }
        let metresPerDegree = 111_320.0
        let kx = metresPerDegree * cos(lats[0] * .pi / 180)
        let xs = lons.map { ($0 - lons[0]) * kx }
        let ys = lats.map { ($0 - lats[0]) * metresPerDegree }
        var tolerance = toleranceM
        while true {
            let kept = run(xs, ys, tolerance)
            if kept.count <= maxPoints { return kept }
            tolerance *= 2
        }
    }

    /// Iterative, so a long route can't overflow the stack.
    private static func run(_ xs: [Double], _ ys: [Double], _ tolerance: Double) -> [Int] {
        let n = xs.count
        var keep = [Bool](repeating: false, count: n)
        keep[0] = true
        keep[n - 1] = true
        var stack = [(0, n - 1)]
        while let (first, last) = stack.popLast() {
            var farthest = -1
            var farthestDistance = tolerance
            if last - first > 1 {
                for i in (first + 1)..<last {
                    let d = distanceToSegment(xs[i], ys[i], xs[first], ys[first], xs[last], ys[last])
                    if d > farthestDistance { (farthest, farthestDistance) = (i, d) }
                }
            }
            guard farthest >= 0 else { continue }
            keep[farthest] = true
            stack.append((first, farthest))
            stack.append((farthest, last))
        }
        return keep.indices.filter { keep[$0] }
    }

    private static func distanceToSegment(_ px: Double, _ py: Double, _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared == 0 { return hypot(px - ax, py - ay) }
        let t = min(max(((px - ax) * dx + (py - ay) * dy) / lengthSquared, 0), 1)
        return hypot(px - (ax + t * dx), py - (ay + t * dy))
    }
}

/// The pace band rule (root docs/SPEC.md FR-4.6) for the Sync tab's recordings, which aren't on
/// the server: five equal bins over the track's own range of speeds, slowest 0. The server bands
/// every synced track itself; it, Android and this run `testdata/pace-bands.json`.
public enum RouteBands {
    static let count = 5

    /// Point i's band comes from its own speed, and its run starts at point i − 1: the stretch
    /// leading into a point is coloured by how fast it was covered.
    public static func runs(_ speeds: [Double]) -> [RouteMetrics.Band] {
        guard speeds.count >= 2, let lo = speeds.min(), let hi = speeds.max() else { return [] }
        let span = hi - lo == 0 ? 1 : hi - lo
        func band(_ value: Double) -> Int { min(max(Int(floor((value - lo) / span * Double(count))), 0), count - 1) }
        var runs: [RouteMetrics.Band] = []
        var current = -1, start = 0
        for i in 1..<speeds.count {
            let b = band(speeds[i])
            if b != current {
                if current != -1 && i - 1 > start { runs.append(RouteMetrics.Band(band: current, start: start, end: i - 1)) }
                current = b
                start = i - 1
            }
        }
        if speeds.count - 1 > start { runs.append(RouteMetrics.Band(band: current, start: start, end: speeds.count - 1)) }
        return runs
    }
}

extension RecordedTrack {
    /// The route's points kept for drawing (Simplify).
    public var drawnPoints: [RecordedPoint] {
        Simplify.indexes(lats: points.map(\.lat), lons: points.map(\.lon)).map { points[$0] }
    }

    /// Its pace bands, worked out on the phone as the server does a synced track's: each kept
    /// vertex's speed is the distance from the vertex before over the whole seconds between them,
    /// 0 where no second passed, and the first takes the second's. Android's SyncCandidates.metrics.
    public var metrics: RouteMetrics { metrics(kept: drawnPoints) }

    /// metrics over the points already kept for drawing, so a route is simplified once.
    func metrics(kept: [RecordedPoint]) -> RouteMetrics {
        var speeds = [Double](repeating: 0, count: kept.count)
        for i in kept.indices.dropFirst() {
            let a = kept[i - 1], b = kept[i]
            let dt = floor(b.time.timeIntervalSince1970) - floor(a.time.timeIntervalSince1970)
            if dt > 0 { speeds[i] = Recording.distance(a, b) / dt }
        }
        if speeds.count > 1 { speeds[0] = speeds[1] }
        return RouteMetrics(trackID: id, points: kept.map { RouteMetrics.Point(lon: $0.lon, lat: $0.lat, time: floor($0.time.timeIntervalSince1970)) },
                            bands: RouteBands.runs(speeds))
    }
}
