import Foundation
import HoldMyTrackCore
import Testing

@testable import HoldMyTrack

/// The panel's counts and moments as Android writes them (apps/docs/SPEC.md FR-2.7), in
/// the test run's English.
@MainActor
struct PanelFormatTests {
    private let format = PanelFormat(account: Account(email: "a@b.c", isDemo: false, emailVerified: true, country: "US", unitSystem: "metric"))

    @Test func aCountIsPluralAndGrouped() {
        #expect(format.trackCount(1) == "1 track")
        #expect(format.trackCount(6) == "6 tracks")
        #expect(format.trackCount(1234) == "1,234 tracks")
    }

    @Test func aRadiusIsInTheAccountsUnits() {
        #expect(format.radius(2000) == "2,000 m")
        let imperial = PanelFormat(account: Account(email: "a@b.c", isDemo: false, emailVerified: true, country: "US", unitSystem: "imperial"))
        #expect(imperial.radius(2000) == "6,562 ft")
    }

    @Test func theFooterCountsTheCheckedAndTheirDistance() {
        #expect(format.checkedFooter(count: 2, meters: 2_400) == "2 checked · \(format.totalDistance(2_400))")
        #expect(format.checkedFooter(count: 1234, meters: 0).hasPrefix("1,234 checked · "))
    }

    @Test func aMomentJoinsTheDateAndTimeWithAComma() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let moment = PanelFormat.dateTime(Date(timeIntervalSince1970: 1_790_000_000), zone: utc)
        // iOS writes a narrow no-break space before PM.
        #expect(moment == "Sep 21, 2026, 2:13\u{202F}PM", "Android’s form, without iOS’s “at”")
    }
}
