import Foundation
import Testing

@testable import HoldMyTrackCore

/// The Live Activity's values (apps/ios/docs/SPEC.md FR-5.1).
struct RecordingActivityTests {
    @Test func theClockStartsAsLongAgoAsTheMovingTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(RecordingActivityState.clockStart(moving: 90, at: now) == now.addingTimeInterval(-90))
    }

    @Test func onlyStopsLinkIsStop() {
        #expect(RecordingLink.isStop(URL(string: "holdmytrack://recording/stop")!))
        #expect(!RecordingLink.isStop(URL(string: "holdmytrack://oauth?code=x")!))
        #expect(!RecordingLink.isStop(URL(string: "https://recording/stop")!))
    }
}