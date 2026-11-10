import Foundation
import Testing

@testable import HoldMyTrackCore

/// The area list and Dates (root docs/SPEC.md FR-5.19, FR-5.20) beyond their shared rules.
struct AreaListTests {
    @Test func theViewIsAskedAboutToAMetre() {
        #expect(AreaLoad.box(west: -81.123456, south: 41.000004, east: -81.0, north: 41.5) == [-81.12346, 41.0, -81.0, 41.5])
        #expect(AreaLoad.same([8, 47, 9, 48], [8.000001, 47, 9, 48]))
        #expect(!AreaLoad.same([8, 47, 9, 48], [8.0001, 47, 9, 48]))
        #expect(!AreaLoad.same(nil, [8, 47, 9, 48]))
    }

    @Test func datesAreTheServersFromAndTo() {
        #expect(DateFilter.allTime.query.isEmpty)
        #expect(DateFilter(after: "2026-06-03").query == [URLQueryItem(name: "from", value: "2026-06-03")])
        #expect(DateFilter(after: "2026-06-03", before: "2026-06-10").query.map(\.name) == ["from", "to"])
    }

    @Test func aButtonsDayDropsThisYear() {
        let en = Locale(identifier: "en_US")
        #expect(DateFilter.short("2026-06-03", today: "2026-11-09", locale: en) == "Jun 3")
        #expect(DateFilter.short("2025-06-03", today: "2026-11-09", locale: en) == "Jun 3, 2025")
    }

    @Test func todayIsTheAccountsZones() {
        let late = Date(timeIntervalSince1970: 1_793_750_400) // 2026-11-04 04:00 UTC
        #expect(DateFilter.today(in: "UTC", now: late) == "2026-11-04")
        #expect(DateFilter.today(in: "America/New_York", now: late) == "2026-11-03")
    }
}
