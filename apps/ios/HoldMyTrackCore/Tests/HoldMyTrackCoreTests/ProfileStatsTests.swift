import Testing

import HoldMyTrackCore

/// The You tab's numbers and recent weeks, by the web Profile page's rules.
struct ProfileStatsTests {
    private func day(_ date: String, _ count: Int = 1, _ meters: Double = 1000) -> TrackDay {
        TrackDay(date: date, count: count, distanceMeters: meters)
    }

    @Test func sumsDaysAndTheLongestRunOfConsecutiveOnes() {
        let totals = ProfileStats.totals([day("2026-02-27", 2), day("2026-02-28"), day("2026-03-01"), day("2026-03-05", 1, 500)])
        #expect(totals.count == 5)
        #expect(totals.distanceMeters == 3500)
        #expect(totals.activeDays == 4)
        #expect(totals.longestStreakDays == 3, "across the end of February")
        let none = ProfileStats.totals([])
        #expect(none.count == 0 && none.activeDays == 0 && none.longestStreakDays == 0)
    }

    @Test func recentWeeksRunSundayToSaturdayEndingThisWeekWithLaterDaysBlank() {
        // 2026-11-21 is a Saturday; 2026-11-19 a Thursday.
        let full = ProfileStats.recentWeeks([day("2026-11-15", 5), day("2026-11-21", 2)], today: "2026-11-21", weeks: 2)
        #expect(full.count == 14)
        #expect(full[7] == 3, "Sunday the 15th, three or more")
        #expect(full[13] == 2, "Saturday the 21st, the last cell")
        #expect(full[0] == 0)
        let midweek = ProfileStats.recentWeeks([], today: "2026-11-19", weeks: 1)
        #expect(midweek == [0, 0, 0, 0, 0, -1, -1], "Friday and Saturday haven't come")
    }

    @Test func initialsTakeTheFirstTwoWordsOrTheEmailsName() {
        #expect(AccountCard.initials("Sam Taylor") == "ST")
        #expect(AccountCard.initials("ann.lee@example.com") == "AL")
        #expect(AccountCard.initials("bob@example.com") == "B")
        #expect(AccountCard.initials("") == "")
    }

    @Test func thePlaceLineNeedsACountry() {
        #expect(AccountCard.place(country: "United States", timezone: "America/New_York", unit: "mi") == "United States · America/New_York · mi")
        #expect(AccountCard.place(country: "", timezone: "UTC", unit: "km") == nil)
        #expect(AccountCard.place(country: nil, timezone: "UTC", unit: "km") == nil)
    }
}
