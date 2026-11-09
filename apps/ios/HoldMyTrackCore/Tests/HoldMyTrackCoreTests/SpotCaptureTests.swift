import Foundation
import Testing

@testable import HoldMyTrackCore

/// The capture rule, 30 seconds inside counting fixes accurate to 25 m, and its geometry
/// (apps/android/docs/SPEC.md FR-2.8): Android's SpotCaptureTest and SpotGeometryTest.
struct SpotCaptureTests {
    // About 111 m on a side at the equator, with a 22 m hole in the middle.
    private let outer = [GeoPoint(lat: 0, lon: 0), GeoPoint(lat: 0, lon: 0.001), GeoPoint(lat: 0.001, lon: 0.001), GeoPoint(lat: 0.001, lon: 0), GeoPoint(lat: 0, lon: 0)]
    private let hole = [GeoPoint(lat: 0.0004, lon: 0.0004), GeoPoint(lat: 0.0004, lon: 0.0006), GeoPoint(lat: 0.0006, lon: 0.0006), GeoPoint(lat: 0.0006, lon: 0.0004), GeoPoint(lat: 0.0004, lon: 0.0004)]
    private var square: SpotArea { [[outer]] }
    private let inside = GeoPoint(lat: 0.0005, lon: 0.0005)
    private let outside = GeoPoint(lat: 0.002, lon: 0.0005)

    private func capture() -> SpotCapture { SpotCapture(area: square, anchor: inside) }

    /// A fix a second from fromS to toS seconds, at point.
    @discardableResult
    private func fixes(_ c: inout SpotCapture, _ fromS: Int, _ toS: Int, _ point: GeoPoint, accuracyM: Double = 5) -> SpotCapture.State {
        for s in fromS...toS { c.fix(point, accuracyM: accuracyM, timeMs: s * 1000) }
        return c.state
    }

    // MARK: Geometry

    @Test func insideOutsideAndAHole() {
        #expect(SpotGeometry.contains(square, inside))
        #expect(!SpotGeometry.contains(square, outside))
        #expect(!SpotGeometry.contains([[outer, hole]], inside), "a hole is outside")
        #expect(SpotGeometry.contains([[outer, hole]], GeoPoint(lat: 0.0002, lon: 0.0002)))
    }

    @Test func anyPolygonOfAMultiPolygonCounts() {
        let far = [GeoPoint(lat: 1, lon: 1), GeoPoint(lat: 1, lon: 1.001), GeoPoint(lat: 1.001, lon: 1.001), GeoPoint(lat: 1.001, lon: 1), GeoPoint(lat: 1, lon: 1)]
        #expect(SpotGeometry.contains([[outer], [far]], GeoPoint(lat: 1.0005, lon: 1.0005)))
    }

    @Test func distanceIsToTheNearestEdgeAndZeroInside() throws {
        #expect(SpotGeometry.distanceM(square, inside) == 0)
        #expect(abs(SpotGeometry.distanceM(square, outside) - 111.2) < 0.5)
        let nearest = try #require(SpotGeometry.nearestPoint(square, outside))
        #expect(abs(nearest.lat - 0.001) < 1e-9)
        #expect(abs(nearest.lon - 0.0005) < 1e-9)
    }

    @Test func bearingIsClockwiseFromNorth() {
        let from = GeoPoint(lat: 0, lon: 0)
        #expect(abs(SpotGeometry.bearing(from: from, to: GeoPoint(lat: 0.001, lon: 0))) < 1e-6)
        #expect(abs(SpotGeometry.bearing(from: from, to: GeoPoint(lat: 0, lon: 0.001)) - 90) < 1e-6)
        #expect(abs(SpotGeometry.bearing(from: from, to: GeoPoint(lat: -0.001, lon: 0)) - 180) < 1e-6)
        #expect(abs(SpotGeometry.bearing(from: from, to: GeoPoint(lat: 0, lon: -0.001)) - 270) < 1e-6)
    }

    // MARK: The count

    @Test func thirtySecondsInsideCaptures() {
        var c = capture()
        guard case .holding = fixes(&c, 0, 29, inside) else { Issue.record("not holding"); return }
        #expect(fixes(&c, 30, 30, inside) == .captured(at: inside))
    }

    @Test func outsideIsAwayWithDistanceAndBearing() {
        var c = capture()
        guard case let .away(distance, bearing, _, _) = fixes(&c, 0, 0, outside) else { Issue.record("not away"); return }
        #expect(abs(distance - 111.2) < 0.5)
        #expect(abs(bearing - 180) < 1e-6)
    }

    @Test func steppingOutsideStartsTheHoldAgain() {
        var c = capture()
        fixes(&c, 0, 20, inside)
        fixes(&c, 21, 21, outside)
        #expect(fixes(&c, 22, 42, inside) == .holding(heldMs: 20_000, at: inside))
        #expect(fixes(&c, 43, 52, inside) == .captured(at: inside))
    }

    @Test func inaccurateFixesAreIgnored() {
        var c = capture()
        #expect(fixes(&c, 0, 40, inside, accuracyM: 40) == .locating)
        #expect(c.fix(inside, accuracyM: nil, timeMs: 41_000) == .locating)
        #expect(c.fix(inside, accuracyM: -1, timeMs: 42_000) == .locating, "iOS's negative accuracy is an invalid fix")
        fixes(&c, 50, 60, inside)
        // A coarse fix outside doesn't break the hold either.
        c.fix(outside, accuracyM: 60, timeMs: 61_000)
        #expect(fixes(&c, 61, 61, inside) == .holding(heldMs: 11_000, at: inside))
    }

    @Test func aGapInFixesCountsOnlyAFewSeconds() {
        var c = capture()
        fixes(&c, 0, 10, inside)
        // Five minutes away: only maxGapMs of it counts.
        #expect(c.fix(inside, accuracyM: 5, timeMs: 310_000) == .holding(heldMs: 13_000, at: inside))
    }

    @Test func resetStartsOver() {
        var c = capture()
        fixes(&c, 0, 30, inside)
        c.reset()
        #expect(c.state == .locating)
        #expect(fixes(&c, 40, 40, inside) == .holding(heldMs: 0, at: inside))
    }

    @Test func secondsLeftRoundUp() {
        #expect(SpotCapture.secondsLeft(heldMs: 0) == 30)
        #expect(SpotCapture.secondsLeft(heldMs: 29_001) == 1)
    }

    @Test func shortDistancesAreMetresOrFeet() {
        #expect(SpotCapture.short(42.4, imperial: false) == .meters(42))
        #expect(SpotCapture.short(1000, imperial: false) == nil)
        #expect(SpotCapture.short(100, imperial: true) == .feet(328))
        #expect(SpotCapture.short(161, imperial: true) == nil)
    }

    @Test func aCapturesAnswerSaysWhatComesNext() {
        #expect(CaptureOutcome.of(APIError.http(status: 422, code: nil, message: nil)) == .outside)
        #expect(CaptureOutcome.of(APIError.http(status: 410, code: nil, message: nil)) == .gone)
        #expect(CaptureOutcome.of(APIError.http(status: 404, code: nil, message: nil)) == .gone)
        #expect(CaptureOutcome.of(APIError.unreachable) == .retry)
        #expect(CaptureOutcome.of(APIError.http(status: 500, code: nil, message: nil)) == .retry)
    }
}
