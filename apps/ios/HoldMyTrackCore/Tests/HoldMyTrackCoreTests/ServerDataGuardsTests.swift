import Foundation
import Testing

@testable import HoldMyTrackCore

/// Malformed data from the server is shown without its broken part, never a crash.
struct ServerDataGuardsTests {
    @Test func aMalformedDayIsShownAsSent() {
        #expect(DateFilter.short("not-a-date", today: "2026-11-09", locale: Locale(identifier: "en_US")) == "not-a-date")
    }

    @Test func aMoveThatIsntAPairLeavesThePoint() {
        let points = [RoutePoint(lon: 10, lat: 50, t: 1), RoutePoint(lon: 11, lat: 51, t: 2)]
        let moved = EditRouteOps.apply(points, RouteEdit(move: [1: [12], 2: [13, 53]]))
        #expect(moved == [RoutePoint(lon: 10, lat: 50, t: 1), RoutePoint(lon: 13, lat: 53, t: 2)])
    }
}