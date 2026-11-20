import Foundation
import Testing

@testable import HoldMyTrackCore

/// The Live Activity's values (apps/ios/docs/SPEC.md FR-5.1).
struct RecordingActivityTests {
    @Test func theClockStartsAsLongAgoAsTheMovingTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(RecordingActivityState.clockStart(moving: 90, at: now) == now.addingTimeInterval(-90))
    }

    let words = RecordingActivityState.Words(recording: "Recording", paused: "Paused", pause: "Pause", resume: "Resume", stop: "Stop")

    @Test func theActivityShowsRecordingThenPausedWithItsWords() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var r = Recording()
        #expect(RecordingActivityState.of(r, at: t0, distance: "0 km", words: words) == nil)
        r.start(at: t0)
        let running = RecordingActivityState.of(r, at: t0.addingTimeInterval(30), distance: "0.1 km", words: words)
        #expect(running?.paused == false && running?.title == "Recording" && running?.toggle == "Pause" && running?.stop == "Stop")
        #expect(running?.clockStart == t0, "the system ticks the clock from the start")
        r.pause(at: t0.addingTimeInterval(60))
        let paused = RecordingActivityState.of(r, at: t0.addingTimeInterval(500), distance: "0.1 km", words: words)
        #expect(paused?.paused == true && paused?.title == "Paused" && paused?.toggle == "Resume" && paused?.clock == "0:01:00")
        r.resume(at: t0.addingTimeInterval(600))
        #expect(RecordingActivityState.of(r, at: t0.addingTimeInterval(620), distance: "0.1 km", words: words)?.clockStart == t0.addingTimeInterval(540),
                "after a pause the clock starts as long ago as the moving time")
    }

    @Test func aStateThatHasntChangedNeedsNoUpdate() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var r = Recording()
        r.start(at: t0)
        let a = RecordingActivityState.of(r, at: t0.addingTimeInterval(10), distance: "0.1 km", words: words)
        let b = RecordingActivityState.of(r, at: t0.addingTimeInterval(40), distance: "0.1 km", words: words)
        let c = RecordingActivityState.of(r, at: t0.addingTimeInterval(70), distance: "0.2 km", words: words)
        #expect(a == b, "the clock ticks by itself")
        #expect(b != c, "a new distance is sent")
    }

    @Test func onlyStopsLinkIsStop() {
        #expect(RecordingLink.isStop(URL(string: "holdmytrack://recording/stop")!))
        #expect(!RecordingLink.isStop(URL(string: "holdmytrack://oauth?code=x")!))
        #expect(!RecordingLink.isStop(URL(string: "https://recording/stop")!))
    }
}