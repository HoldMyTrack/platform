import Foundation

/// A track point with its moment, in epoch seconds.
public struct TimedPoint: Equatable, Sendable {
    public let lon: Double
    public let lat: Double
    public let t: Double

    public init(lon: Double, lat: Double, t: Double) {
        self.lon = lon
        self.lat = lat
        self.t = t
    }
}

/// What a photo waiting for a place was picked after: a photo the server placed (its moment), or
/// one that waited too (its key, placed or skipped since). nil is nothing: the first of its batch.
public enum PlaceAnchor: Equatable, Sendable {
    case at(t: Double)
    case waiting(String)
}

public struct EmptyTrack: Error {}

/// A track as the Photos tab's slider walks it (root docs/IMPLEMENTATION.md §4.27): the display
/// points with their moments, measured along their length. The slider runs by distance, not
/// time, so a long stop doesn't take up half its travel; a photo's place is still saved as a
/// moment (route_at), which is what the server keeps.
public struct PhotoTrack: Sendable {
    public let points: [TimedPoint]
    /// Meters from the first point to each point.
    public let along: [Double]

    /// How far past the previous photo a waiting one's slider starts: just after it, so photos
    /// picked in the order they were taken walk forward along the route.
    public static let nextPhotoStep = 0.01

    public init(_ points: [TimedPoint]) {
        self.points = points
        var along = [0.0]
        for i in points.indices.dropFirst() {
            along.append(along[i - 1] + PhotoMarkers.haversine(points[i - 1].lat, points[i - 1].lon, points[i].lat, points[i].lon))
        }
        self.along = along
    }

    /// The place fraction (0...1) of the way along the track, with its moment.
    public func point(at fraction: Double) throws -> TimedPoint {
        guard let first = points.first, let last = points.last else { throw EmptyTrack() }
        let total = along[along.count - 1]
        let f = min(1, max(0, fraction))
        if points.count == 1 || total == 0 {
            // No length to walk: go by time instead, from the first moment to the last.
            return TimedPoint(lon: first.lon, lat: first.lat, t: Self.round(first.t + (last.t - first.t) * f))
        }
        let target = f * total
        var i = 1
        while i < points.count - 1 && along[i] < target { i += 1 }
        let a = points[i - 1]
        let b = points[i]
        let span = along[i] - along[i - 1]
        let k = span > 0 ? (target - along[i - 1]) / span : 0
        return TimedPoint(lon: a.lon + (b.lon - a.lon) * k, lat: a.lat + (b.lat - a.lat) * k, t: Self.round(a.t + (b.t - a.t) * k))
    }

    /// How far along the track (0...1) the moment t is: the inverse of point(at:), for where a
    /// photo's slider starts. A moment before or after the track is at its end.
    public func fraction(at t: Double) -> Double {
        let total = along.last ?? 0
        guard points.count >= 2 else { return 0 }
        if t <= points[0].t { return 0 }
        if t >= points[points.count - 1].t { return 1 }
        var i = 1
        while i < points.count - 1 && points[i].t < t { i += 1 }
        let a = points[i - 1]
        let b = points[i]
        let k = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
        if total == 0 { return (t - points[0].t) / (points[points.count - 1].t - points[0].t) }
        return (along[i - 1] + (along[i] - along[i - 1]) * k) / total
    }

    /// Where a waiting photo's slider starts: just after the photo picked before it, which is
    /// where the next picture of a walk usually is. A previous one that waited is followed by
    /// where the user put it (placed), or past it to its own predecessor if it was skipped (nil).
    /// The first of a batch, or one after nothing placed at all, starts at the route's beginning.
    public func startFraction(anchor: PlaceAnchor?, placed: [String: Double?], anchors: [String: PlaceAnchor?]) -> Double {
        var anchor = anchor
        var seen = 0
        while let current = anchor, seen <= anchors.count {
            switch current {
            case .at(let t): return min(1, fraction(at: t) + Self.nextPhotoStep)
            case .waiting(let key):
                if let at = placed[key] ?? nil { return min(1, at + Self.nextPhotoStep) }
                anchor = anchors[key] ?? nil
            }
            seen += 1
        }
        return 0
    }

    /// Halves up, as the web's Math.round.
    private static func round(_ v: Double) -> Double { (v + 0.5).rounded(.down) }
}
