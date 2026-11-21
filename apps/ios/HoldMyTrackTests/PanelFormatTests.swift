import CoreLocation
import UserNotifications
import Foundation
import HoldMyTrackCore
import Testing

@testable import HoldMyTrack

/// The panel's counts and moments as Android writes them (apps/android/docs/SPEC.md FR-2.7), in
/// the test run's English.
@MainActor
struct PanelFormatTests {
    private let format = PanelFormat(account: Account(email: "a@b.c", isDemo: false, emailVerified: true, country: "US", unitSystem: "metric"))

    @Test func aCountIsPluralAndGrouped() {
        #expect(format.trackCount(1) == "1 track")
        #expect(format.trackCount(6) == "6 tracks")
        #expect(format.trackCount(1234) == "1,234 tracks")
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

/// Settings › Sync's word on the record button.
@MainActor
struct SyncSourcesTests {
    @Test func bothAllowedIsAllowed() {
        #expect(SyncSources.recording(location: .authorizedWhenInUse, notifications: .authorized) == .allowed)
        #expect(SyncSources.recording(location: .authorizedAlways, notifications: .provisional) == .allowed)
    }

    @Test func eitherRefusedIsRefusedSinceIOSWontAskAgain() {
        #expect(SyncSources.recording(location: .denied, notifications: .authorized) == .refused)
        #expect(SyncSources.recording(location: .restricted, notifications: .notDetermined) == .refused)
        #expect(SyncSources.recording(location: .authorizedWhenInUse, notifications: .denied) == .refused)
    }

    @Test func otherwiseTheyreAskedOnTheFirstRecording() {
        #expect(SyncSources.recording(location: .notDetermined, notifications: .notDetermined) == .notAsked)
        #expect(SyncSources.recording(location: .authorizedWhenInUse, notifications: .notDetermined) == .notAsked)
    }
}
