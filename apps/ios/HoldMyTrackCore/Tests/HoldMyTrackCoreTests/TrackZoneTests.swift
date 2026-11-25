import Testing

@testable import HoldMyTrackCore

struct TrackZoneTests {
    @Test func aTracksDayIsInItsOwnZoneThenTheAccounts() {
        // 23:30 UTC on the 20th is the 21st in Berlin and still the 20th in New York.
        let started = "2026-11-20T23:30:00.250Z"
        #expect(TrackZone.day(startedAt: started, own: "America/New_York", account: "Europe/Berlin") == "2026-11-20")
        #expect(TrackZone.day(startedAt: started, own: "", account: "Europe/Berlin") == "2026-11-21")
        #expect(TrackZone.day(startedAt: "2026-11-20T23:30:00Z", own: "Not/AZone", account: "Europe/Berlin") == "2026-11-21")
        #expect(TrackZone.day(startedAt: "yesterday", own: nil, account: nil) == nil)
    }
}
