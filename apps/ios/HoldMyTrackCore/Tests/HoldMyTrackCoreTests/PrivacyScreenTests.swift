import Foundation
import Testing

@testable import HoldMyTrackCore

/// What Privacy and Download your data offer and say.
struct PrivacyScreenTests {
    @Test func theDemoGetsNoAddAndNoDownload() {
        #expect(PrivacyScreen.offersAdd(demo: false) && PrivacyScreen.offersDownload(demo: false))
        #expect(!PrivacyScreen.offersAdd(demo: true) && !PrivacyScreen.offersDownload(demo: true))
    }

    @Test func theFooterCountsHiddenTracksAndSaysAChangeReprocesses() {
        #expect(PrivacyScreen.footer(locations: 0, hidden: 3, demo: false) == nil, "no locations, no footer")
        #expect(PrivacyScreen.footer(locations: 2, hidden: 0, demo: false) == PrivacyScreen.Footer(hidden: 0, reprocess: true))
        #expect(PrivacyScreen.footer(locations: 2, hidden: nil, demo: false) == PrivacyScreen.Footer(hidden: nil, reprocess: true), "the count still on its way")
        #expect(PrivacyScreen.footer(locations: 2, hidden: 4, demo: true) == PrivacyScreen.Footer(hidden: 4, reprocess: false), "the demo changes nothing")
        #expect(PrivacyScreen.footer(locations: 2, hidden: nil, demo: true) == nil)
    }

    @Test func aReadyArchiveTotalsItsPartsAndReadsTheServersDate() throws {
        let parts = [ExportStatus.Part(n: 1, size: 1000, name: "a.zip", url: "/a"), ExportStatus.Part(n: 2, size: 500, name: "b.zip", url: "/b")]
        let ready = DataExportText.status(ExportStatus(state: .ready, expiresAt: "2026-11-28T09:12:33.481902Z", parts: parts))
        guard case .ready(let total, let until) = ready else { Issue.record("not ready"); return }
        #expect(total == 1500)
        let expected = Date(timeIntervalSince1970: 1_795_857_153.481902)
        #expect(until.map { abs($0.timeIntervalSince(expected)) < 0.001 } == true, "fractional seconds, as Go writes them")
        #expect(DataExportText.date("2026-11-28T09:12:33Z") != nil, "and without")
        #expect(DataExportText.status(ExportStatus(state: .ready, expiresAt: "soon", parts: parts)) == .ready(totalBytes: 1500, until: nil))
    }

    @Test func theRequestButtonHidesWhilePreparingAndAsksAgainOnceReady() {
        #expect(!DataExportText.offersRequest(.preparing))
        #expect(DataExportText.offersRequest(.none) && DataExportText.offersRequest(.failed))
        #expect(DataExportText.requestsAgain(.ready) && !DataExportText.requestsAgain(.none))
        #expect(DataExportText.status(ExportStatus(state: .none, expiresAt: nil, parts: [])) == .none)
    }
}
