import Foundation
import Testing

@testable import HoldMyTrackCore

/// The date slider's window over the account's activity days (root docs/SPEC.md FR-6).
struct ActivityDaysTests {
    /// n activity days, one a day from 2026-10-01.
    private func dates(_ n: Int, from day: Int = 1) -> [String] {
        // Typed one step at a time: CI's compiler gives up on the arithmetic as one expression.
        (0..<n).map { (i: Int) -> String in
            let offset: Int = day + i - 1
            let month: Int = 10 + offset / 31
            let dayOfMonth: Int = offset % 31 + 1
            return String(format: "2026-%02d-%02d", month, dayOfMonth)
        }
    }

    @Test func aFirstPageFillsTheWindowFromTheNewestEnd() {
        var days = ActivityDays(windowDays: 7)
        #expect(!days.ready)
        days.reloaded(days: dates(10), earliest: "2026-10-01")
        #expect(days.ready)
        #expect(days.visibleDays == Array(dates(10).suffix(7)))
        #expect(days.canPanEarlier)
        #expect(!days.canPanLater)
    }

    @Test func panningMovesByActivityDaysAndStaysInTheHistory() {
        var days = ActivityDays(windowDays: 7)
        days.reloaded(days: dates(10), earliest: "2026-10-01")
        days.pan(by: -2)
        #expect(days.visibleDays == Array(dates(10)[1..<8]))
        #expect(days.canPanLater)
        days.pan(by: -50)
        #expect(days.visibleDays == Array(dates(10).prefix(7)))
        #expect(!days.canPanEarlier)
        days.pan(by: 50)
        #expect(days.visibleDays == Array(dates(10).suffix(7)))
    }

    @Test func nearTheLoadedEdgeTheEarlierPageIsWanted() {
        var days = ActivityDays(windowDays: 7)
        days.reloaded(days: dates(10, from: 20), earliest: "2026-10-01")
        #expect(days.wantsEarlier == "2026-10-20")
        days.reloaded(days: dates(10), earliest: "2026-10-01")
        #expect(days.wantsEarlier == nil, "nothing is older than the earliest day")
    }

    @Test func aPanPastTheLoadedDaysSettlesWhenTheirPageArrives() {
        var days = ActivityDays(windowDays: 7)
        days.reloaded(days: dates(10, from: 11), earliest: "2026-10-01")
        days.pan(by: -6)
        #expect(days.visibleDays.first == "2026-10-11")
        days.prepended(days: dates(10), before: "2026-10-11", earliest: "2026-10-01")
        #expect(days.visibleDays.first == "2026-10-08", "the 3 days the pan still owed")
    }

    @Test func aPageForAnOlderLoadIsDropped() {
        var days = ActivityDays(windowDays: 7)
        days.reloaded(days: dates(10, from: 11), earliest: "2026-10-01")
        days.prepended(days: dates(10), before: "2026-10-05", earliest: "2026-10-01")
        #expect(days.days == dates(10, from: 11))
    }

    @Test func aResizeOnTheNewestEndStaysThere() {
        var days = ActivityDays(windowDays: 7)
        days.reloaded(days: dates(20), earliest: "2026-10-01")
        days.resize(10, selection: DateRange(from: "2026-10-18", to: "2026-10-20"))
        #expect(days.visibleDays == Array(dates(20).suffix(10)))
    }

    @Test func aShiftMovesTheRangeItsLengthAndTheWindowWithIt() {
        var days = ActivityDays(windowDays: 7)
        days.reloaded(days: dates(20), earliest: "2026-10-01")
        let result = days.shift(DateRange(from: "2026-10-15", to: "2026-10-16"), dir: -1)
        #expect(result.range == DateRange(from: "2026-10-13", to: "2026-10-14"))
        #expect(days.visibleDays.contains("2026-10-13"))
        #expect(days.shift(DateRange(from: "2026-10-19", to: "2026-10-20"), dir: 1).range == nil)
    }
}

struct RangeLabelTests {
    private func label(_ from: String, _ to: String, _ locale: String = "en") -> String {
        RangeLabel.of(DateRange(from: from, to: to), locale: Locale(identifier: locale))
    }

    @Test func theRangeSaysItsYearOnce() {
        #expect(label("2026-10-03", "2026-10-03") == "3 Oct 2026")
        #expect(label("2026-09-24", "2026-09-28") == "24 – 28 Sep 2026")
        #expect(label("2026-09-24", "2026-10-03") == "24 Sep – 3 Oct 2026")
        #expect(label("2025-12-28", "2026-01-03") == "28 Dec 2025 – 3 Jan 2026")
    }

    @Test func russianMonthsAreTheirOwn() {
        #expect(label("2026-09-24", "2026-09-28", "ru").hasPrefix("24 – 28 сент"))
    }
}

struct DateSliderSupportTests {
    @Test func boxesOnOneSideOfTheAntimeridianUnionAsAlways() {
        #expect(MapFraming.union([]) == nil)
        #expect(MapFraming.union([[-81.7, 41.4, -81.6, 41.5], [-1.0, 51.0, 1.0, 51.5]]) == [-81.7, 41.4, 1.0, 51.5])
    }

    @Test func boxesEitherSideOfItGoTheShortWayAcrossThePacific() {
        // New Zealand and Hawaii.
        let box = MapFraming.union([[174.7, -41.3, 174.8, -41.2], [-157.9, 21.2, -157.8, 21.3]])!
        #expect(abs(box[0] - 174.7) < 1e-9 && abs(box[2] - 202.2) < 1e-9)
    }

    @Test func boxesAllRoundTheWorldGiveTheWholeWorld() {
        #expect(MapFraming.union([[-180, 0, -60, 1], [-60, 0, 60, 1], [60, 0, 180, 1]]) == [-180, 0, 180, 1])
    }

    @Test func todayIsTheAccountsDate() {
        let now = Date(timeIntervalSince1970: 1_793_750_400) // 2026-11-04 00:00 UTC
        #expect(DefaultRange.today(in: "UTC", now: now) == "2026-11-04")
        #expect(DefaultRange.today(in: "America/New_York", now: now) == "2026-11-03")
    }

    @Test func theTracksQueryIsTheRange() {
        #expect(MapFraming.tracksQuery(DateRange(from: "2026-10-01", to: "2026-10-05")) == "from=2026-10-01&to=2026-10-05")
        #expect(MapFraming.tracksQuery(nil) == "")
    }
}
