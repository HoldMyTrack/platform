import Foundation
import Testing

@testable import HoldMyTrackCore

/// A Sync row's line and pace bands, worked out on the phone (apps/android/docs/SPEC.md FR-3.2).
struct RouteShapeTests {
    @Test func theServersPaceBandCases() throws {
        let file = Contract().root.appending(path: "testdata/pace-bands.json")
        let json = try #require(JSONValue.parse(Data(contentsOf: file)))
        let cases = try #require(json["cases"]?.array)
        #expect(!cases.isEmpty)
        for c in cases {
            let speeds = c["input"]?["speeds"]?.array?.compactMap(\.number) ?? []
            let expected = (c["expected"]?.array ?? []).map {
                RouteMetrics.Band(band: Int($0["band"]!.number!), start: Int($0["start"]!.number!), end: Int($0["end"]!.number!))
            }
            #expect(RouteBands.runs(speeds) == expected, "\(c["name"]?.string ?? "")")
        }
    }

    @Test func aStraightRunKeepsItsEndsAndABendIsKept() {
        // Three points on one meridian: the middle one adds nothing to the drawn line.
        #expect(Simplify.indexes(lats: [50, 50.001, 50.002], lons: [10, 10, 10]) == [0, 2])
        // The middle one 100 m off the line between its neighbours stays.
        #expect(Simplify.indexes(lats: [50, 50.001, 50.002], lons: [10, 10.0014, 10]) == [0, 1, 2])
        #expect(Simplify.indexes(lats: [50], lons: [10]) == [0])
    }

    @Test func pastTheCapTheToleranceGrowsUntilTheyFit() {
        let n = 50
        let lats = (0..<n).map { 50 + Double($0) * 0.001 }
        let lons = (0..<n).map { 10 + ($0 % 2 == 0 ? 0 : 0.0005) }
        let kept = Simplify.indexes(lats: lats, lons: lons, maxPoints: 10)
        #expect(kept.count <= 10)
        #expect(kept.first == 0 && kept.last == n - 1)
    }

    @Test func eachVertexTakesTheSpeedFromTheOneBeforeAndTheFirstTakesTheSeconds() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        // 0.001° of latitude is about 111 m: 10 s, then 100 s, then a zigzag kept by the bend.
        let points = [
            RecordedPoint(lat: 50, lon: 10, ele: nil, time: t0),
            RecordedPoint(lat: 50.001, lon: 10.002, ele: nil, time: t0.addingTimeInterval(10)),
            RecordedPoint(lat: 50.002, lon: 10, ele: nil, time: t0.addingTimeInterval(110)),
        ]
        let track = RecordedTrack(id: "r", startedAt: t0, endedAt: t0.addingTimeInterval(110), movingSeconds: 110, meters: 300, type: "walk", points: points)
        let metrics = track.metrics
        #expect(metrics.trackID == "r")
        #expect(metrics.points.count == 3)
        #expect(metrics.bands == [RouteMetrics.Band(band: 4, start: 0, end: 1), RouteMetrics.Band(band: 0, start: 1, end: 2)], "fast then slow")
    }
}
