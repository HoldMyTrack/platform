import Foundation

/// A position in degrees.
public struct GeoPoint: Equatable, Sendable {
    public let lat: Double
    public let lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

/// A place's area as `GET /v1/spots/{id}` sends it: polygons, each an outer ring then its holes,
/// each ring closed.
public typealias SpotArea = [[[GeoPoint]]]

/// What capture measures a position against (apps/android/docs/SPEC.md FR-2.8): inside a place's
/// area or not, how far from it, and which way. A place is metres to hundreds of metres across,
/// so each measure is taken on a flat projection centred on the position, equirectangular with x
/// scaled by cos(latitude), well under a metre off at that size.
public enum SpotGeometry {
    private static let earthRadiusM = 6_371_008.8

    /// Inside the outer ring of one of the polygons and none of its holes.
    public static func contains(_ area: SpotArea, _ point: GeoPoint) -> Bool {
        area.contains { polygon in
            guard let outer = polygon.first else { return false }
            return inRing(outer, point) && !polygon.dropFirst().contains { inRing($0, point) }
        }
    }

    /// Metres from point to the area's nearest edge, 0 inside it.
    public static func distanceM(_ area: SpotArea, _ point: GeoPoint) -> Double {
        contains(area, point) ? 0 : nearest(area, point)?.distance ?? .infinity
    }

    /// The point on the area's edge nearest point, where the guide line runs to.
    public static func nearestPoint(_ area: SpotArea, _ point: GeoPoint) -> GeoPoint? { nearest(area, point)?.point }

    /// The initial bearing from one point to another, degrees clockwise from north, 0 until 360.
    public static func bearing(from: GeoPoint, to: GeoPoint) -> Double {
        let lat1 = from.lat * .pi / 180, lat2 = to.lat * .pi / 180
        let dLon = (to.lon - from.lon) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Even-odd ray casting on raw degrees: fine for a ring that doesn't cross the antimeridian.
    private static func inRing(_ ring: [GeoPoint], _ point: GeoPoint) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.lat > point.lat) != (b.lat > point.lat),
               point.lon < (b.lon - a.lon) * (point.lat - a.lat) / (b.lat - a.lat) + a.lon {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    private static func nearest(_ area: SpotArea, _ point: GeoPoint) -> (point: GeoPoint, distance: Double)? {
        let mPerLat = earthRadiusM * .pi / 180
        let mPerLon = mPerLat * cos(point.lat * .pi / 180)
        func x(_ p: GeoPoint) -> Double { (p.lon - point.lon) * mPerLon }
        func y(_ p: GeoPoint) -> Double { (p.lat - point.lat) * mPerLat }
        var best: (point: GeoPoint, distance: Double)?
        for ring in area.joined() where ring.count >= 2 {
            for i in 0..<(ring.count - 1) {
                let ax = x(ring[i]), ay = y(ring[i]), bx = x(ring[i + 1]), by = y(ring[i + 1])
                let dx = bx - ax, dy = by - ay
                let lengthSq = dx * dx + dy * dy
                // The origin is the position itself: project it onto the segment, clamped to it.
                let t = lengthSq == 0 ? 0 : min(max(-(ax * dx + ay * dy) / lengthSq, 0), 1)
                let px = ax + t * dx, py = ay + t * dy
                let d = hypot(px, py)
                if best == nil || d < best!.distance {
                    best = (GeoPoint(lat: point.lat + py / mPerLat, lon: point.lon + px / mPerLon), d)
                }
            }
        }
        return best
    }
}

/// Capture's count (apps/android/docs/SPEC.md FR-2.8): fed location fixes, it says whether the
/// user is on the way to the place, holding inside it, or has held for holdMs and captured it.
/// Only a fix accurate to maxAccuracyM counts: a coarse one can land inside a place its owner is
/// only walking past. A counted fix outside starts the hold again. The hold runs only on fixes, so
/// a gap longer than maxGapMs, the app away or GPS gone, adds no more than that.
public struct SpotCapture: Sendable {
    public enum State: Equatable, Sendable {
        /// No fix accurate enough yet.
        case locating
        /// Outside: metres to the area's edge and the bearing to it, from the fix to the nearest point.
        case away(distanceM: Double, bearing: Double, from: GeoPoint, to: GeoPoint)
        /// Inside, held for heldMs so far, at the last fix.
        case holding(heldMs: Int, at: GeoPoint)
        /// Held long enough; at is the last fix inside, which the server checks the capture by.
        case captured(at: GeoPoint)
    }

    public static let holdMs = 30_000
    /// A fix less accurate than this is ignored.
    public static let maxAccuracyM = 25.0
    /// The most one gap between fixes inside can add: fixes come every second, so a longer gap
    /// means the app wasn't reading them.
    public static let maxGapMs = 3_000

    let area: SpotArea
    let anchor: GeoPoint
    public private(set) var state = State.locating
    private var lastInsideMs: Int?
    private var heldMs = 0

    public init(area: SpotArea, anchor: GeoPoint) {
        self.area = area
        self.anchor = anchor
    }

    /// One fix; timeMs is its own time, on one clock throughout. Nil accuracy is unknown.
    @discardableResult
    public mutating func fix(_ point: GeoPoint, accuracyM: Double?, timeMs: Int) -> State {
        if case .captured = state { return state }
        guard let accuracyM, accuracyM >= 0, accuracyM <= Self.maxAccuracyM else { return state }
        if SpotGeometry.contains(area, point) {
            if let last = lastInsideMs, timeMs > last { heldMs += min(timeMs - last, Self.maxGapMs) }
            lastInsideMs = timeMs
            state = heldMs >= Self.holdMs ? .captured(at: point) : .holding(heldMs: heldMs, at: point)
        } else {
            lastInsideMs = nil
            heldMs = 0
            let to = SpotGeometry.nearestPoint(area, point) ?? anchor
            state = .away(distanceM: SpotGeometry.distanceM(area, point), bearing: SpotGeometry.bearing(from: point, to: to), from: point, to: to)
        }
        return state
    }

    /// The server saw the position outside: start over.
    public mutating func reset() {
        state = .locating
        lastInsideMs = nil
        heldMs = 0
    }

    /// Whole seconds still to hold, rounded up.
    public static func secondsLeft(heldMs: Int) -> Int { (holdMs - heldMs + 999) / 1000 }

    /// How far to the place: metres, or feet for an imperial account, under a kilometre or a
    /// tenth of a mile; past that nil, and the panel's own distance says it.
    public enum Short: Equatable, Sendable { case meters(Int), feet(Int) }

    public static func short(_ meters: Double, imperial: Bool) -> Short? {
        if imperial { return meters < 160.9344 ? .feet(Int((meters * 3.28084).rounded())) : nil }
        return meters < 1000 ? .meters(Int(meters.rounded())) : nil
    }
}

/// What a capture's answer means for capture (root docs/SPEC.md FR-14.6).
public enum CaptureOutcome: Equatable, Sendable {
    case saved(spotID: Int, at: Date)
    /// The server saw the position outside the area: the count starts again.
    case outside
    /// The place was retired since the map loaded it: nothing to capture.
    case gone
    /// Not sent or not answered: tried again.
    case retry

    public static func of(_ error: Error) -> CaptureOutcome {
        switch error as? APIError {
        case .http(422, _, _): .outside
        case .http(404, _, _), .http(410, _, _): .gone
        default: .retry
        }
    }
}

extension APIClient {
    /// `GET /v1/spots/{id}`: the place's area, what capture measures against. A place retired
    /// since the map loaded it is a 404 to an account that hasn't captured it.
    public func spotArea(_ id: Int) async throws -> SpotArea {
        let json: SpotDetailJSON = try decode(try await send("GET", "v1/spots/\(id)"))
        return json.area.coordinates.map { polygon in polygon.map { ring in ring.compactMap { $0.count >= 2 ? GeoPoint(lat: $0[1], lon: $0[0]) : nil } } }
    }

    /// `POST /v1/spots/{id}/captures` at the last position inside; the server checks it against
    /// the area, and a place already captured answers the first capture.
    public func captureSpot(_ id: Int, at point: GeoPoint) async -> CaptureOutcome {
        do {
            let json: SpotCaptureJSON = try decode(try await send("POST", "v1/spots/\(id)/captures", body: SpotCaptureRequestJSON(lat: point.lat, lon: point.lon)))
            guard let at = Self.instant(json.capturedAt) else { return .retry }
            return .saved(spotID: json.spotID, at: at)
        } catch {
            return CaptureOutcome.of(error)
        }
    }
}