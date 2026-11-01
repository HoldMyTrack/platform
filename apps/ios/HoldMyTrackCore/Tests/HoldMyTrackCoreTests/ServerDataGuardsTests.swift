import Testing

@testable import HoldMyTrackCore

/// Malformed data from the server is shown without its broken part, never a crash.
struct ServerDataGuardsTests {
    @Test func aMalformedDayGetsNoMonthLabel() {
        let ticks = SliderRules.ticks(["2026-09-01", "not-a-date", "2026-10-01"])
        #expect(ticks.count == 4)
        #expect(ticks[0].month == 9)
    }

    @Test func aMoveThatIsntAPairLeavesThePoint() {
        let points = [TrackPoint(lon: 10, lat: 50, t: 1), TrackPoint(lon: 11, lat: 51, t: 2)]
        let moved = EditTrackOps.apply(points, TrackEdit(move: [1: [12], 2: [13, 53]]))
        #expect(moved == [TrackPoint(lon: 10, lat: 50, t: 1), TrackPoint(lon: 13, lat: 53, t: 2)])
    }
}