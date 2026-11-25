import Foundation
import Testing

@testable import HoldMyTrackCore

/// Recording as values (apps/ios/docs/SPEC.md FR-5.1): the button's tap, moving time, distance
/// across pauses, which fixes are kept, what Stop keeps, and the per-account store.
struct RecordingTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func point(_ lat: Double, _ lon: Double, _ seconds: TimeInterval) -> RecordedPoint {
        RecordedPoint(lat: lat, lon: lon, ele: nil, time: t0.addingTimeInterval(seconds))
    }

    @Test func aTapStartsPausesAndResumesAndNeverStops() {
        #expect(RecordTap.of(.idle, access: .precise) == .start)
        #expect(RecordTap.of(.recording, access: .precise) == .pause)
        #expect(RecordTap.of(.paused, access: .precise) == .resume)
    }

    @Test func startingNeedsPreciseLocation() {
        #expect(RecordTap.of(.idle, access: .notAsked) == .askLocation)
        #expect(RecordTap.of(.idle, access: .approximate) == .askPrecise)
        #expect(RecordTap.of(.idle, access: .denied) == .refused)
        #expect(RecordTap.of(.recording, access: .denied) == .pause, "a running recording isn't held up by access")
    }

    @Test func movingTimeLeavesPausesOut() {
        var r = Recording()
        r.start(at: t0)
        r.pause(at: t0.addingTimeInterval(100))
        #expect(r.moving(at: t0.addingTimeInterval(500)) == 100)
        r.resume(at: t0.addingTimeInterval(500))
        #expect(r.moving(at: t0.addingTimeInterval(530)) == 130)
    }

    @Test func noDistanceIsCountedAcrossAPause() {
        var r = Recording()
        r.start(at: t0)
        r.add(point(0, 0, 0), accuracy: 5)
        r.add(point(0, 0.001, 10), accuracy: 5)
        let walked = r.meters
        #expect(abs(walked - 111.19) < 0.5)
        r.pause(at: t0.addingTimeInterval(20))
        let kept1 = r.add(point(0, 0.01, 30), accuracy: 5)
        #expect(!kept1, "nothing is kept while paused")
        r.resume(at: t0.addingTimeInterval(40))
        r.add(point(0, 0.01, 50), accuracy: 5)
        #expect(r.meters == walked, "the first fix after a pause is a fresh baseline")
        r.add(point(0, 0.011, 60), accuracy: 5)
        #expect(abs(r.meters - 2 * walked) < 0.5)
        #expect(r.points.count == 4)
    }

    @Test func vagueOrTooFrequentFixesAreDropped() {
        var r = Recording()
        r.start(at: t0)
        let kept2 = r.add(point(0, 0, 0), accuracy: 65)
        #expect(!kept2, "a Wi-Fi position")
        let kept3 = r.add(point(0, 0, 0), accuracy: -1)
        #expect(!kept3, "an invalid one")
        let kept4 = r.add(point(0, 0, 0), accuracy: 10)
        #expect(kept4)
        let kept5 = r.add(point(0, 0.0001, 2), accuracy: 10)
        #expect(!kept5, "too soon")
        let kept6 = r.add(point(0, 0.0001, 3), accuracy: 10)
        #expect(kept6)
    }

    @Test func aPhoneStandingStillAddsNothing() {
        var r = Recording()
        r.start(at: t0)
        r.add(point(0, 0, 0), accuracy: 5)
        for i in 1 ... 20 {
            let kept = r.add(point(0, i % 2 == 0 ? 0.00003 : 0, Double(i) * 5), accuracy: 5)
            #expect(!kept, "3 m of drift")
        }
        #expect(r.points.count == 1 && r.meters == 0)
        let walked = r.add(point(0, 0.00006, 120), accuracy: 5)
        #expect(walked, "6 m on")
    }

    @Test func aFixFromBeforeTheStartOrResumeIsDropped() {
        var r = Recording()
        r.start(at: t0.addingTimeInterval(100))
        let cached = r.add(point(1, 1, 0), accuracy: 5)
        #expect(!cached, "CoreLocation's last fix, from before the start")
        let fresh = r.add(point(0, 0, 100), accuracy: 5)
        #expect(fresh)
        r.pause(at: t0.addingTimeInterval(110))
        r.resume(at: t0.addingTimeInterval(200))
        let stale = r.add(point(0, 0.001, 150), accuracy: 5)
        #expect(!stale, "taken while paused")
        #expect(r.meters == 0)
    }

    @Test func theStatusSaysWhatTheRecordingIsDoing() {
        var r = Recording()
        #expect(RecordingStatus.of(r, at: t0) == .none)
        r.start(at: t0)
        #expect(RecordingStatus.of(r, at: t0.addingTimeInterval(5)) == .waiting(moving: 5), "the clock runs before the first fix")
        r.add(point(0, 0, 1), accuracy: 5)
        #expect(RecordingStatus.of(r, at: t0.addingTimeInterval(5)) == .running(moving: 5, meters: 0))
        r.pause(at: t0.addingTimeInterval(10))
        #expect(RecordingStatus.of(r, at: t0.addingTimeInterval(99)) == .paused(moving: 10, meters: 0))
        #expect(RecordingStatus.clock(3725) == "1:02:05")
        #expect(RecordingStatus.clock(-1) == "0:00:00")
    }

    @Test func aStartOrAStopShowsTheMapAPauseDoesnt() {
        #expect(RecordingStatus.showsMap(stopping: false, state: .idle))
        #expect(RecordingStatus.showsMap(stopping: true, state: .recording))
        #expect(!RecordingStatus.showsMap(stopping: false, state: .recording))
        #expect(!RecordingStatus.showsMap(stopping: false, state: .paused))
    }

    @Test func stopKeepsAMinuteAndTwoPoints() {
        var r = Recording()
        r.start(at: t0)
        r.add(point(0, 0, 0), accuracy: 5)
        r.add(point(0, 0.001, 30), accuracy: 5)
        #expect(r.finished(at: t0.addingTimeInterval(59), type: "unknown") == nil, "under a minute")
        let kept = r.finished(at: t0.addingTimeInterval(60), type: "walk")
        #expect(kept?.points.count == 2 && kept?.type == "walk" && kept?.movingSeconds == 60)
        var still = Recording()
        still.start(at: t0)
        still.add(point(0, 0, 0), accuracy: 5)
        #expect(still.finished(at: t0.addingTimeInterval(600), type: "unknown") == nil, "one point draws no line")
    }

    @Test func aPauseOrResumeOutOfTurnChangesNothing() {
        var r = Recording()
        r.pause(at: t0)
        #expect(r.state == .idle)
        r.start(at: t0)
        r.resume(at: t0.addingTimeInterval(10))
        #expect(r.state == .recording && r.moving(at: t0.addingTimeInterval(10)) == 10)
    }

    @Test func aRecordingShowsOnlyItselfInNormal() {
        #expect(TabMode.shown(picked: .fog, onTracksTab: true, recording: true) == .normal)
        #expect(!MapChrome.modeBarShown(recording: true, editOpen: false, selectionShown: false, onTracksTab: true))
        #expect(TabMode.hiddenGroups(recording: true) == ["tracks", "route-bands"])
        #expect(TabMode.hiddenGroups(recording: false).isEmpty)
        #expect(TabMode.hiddenGroups(recording: false, editingRoute: true) == [Spots.group], "the places step aside for the route editor")
        #expect(TabMode.hiddenGroups(recording: false, syncing: true) == ["tracks", "route-bands"], "the Sync tab's lines stand alone")
        #expect(TabMode.shown(picked: .fog, onTracksTab: true) == .fog)
    }

    @Test func eachAccountKeepsItsOwnRecordings() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "recordings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(root: root)
        var r = Recording()
        r.start(at: t0)
        r.add(point(0, 0, 0), accuracy: 5)
        r.add(point(0, 0.001, 30), accuracy: 5)
        let track = try #require(r.finished(at: t0.addingTimeInterval(90), type: "unknown"))
        try store.save(track, account: "a@example.com")
        #expect(store.list(account: "a@example.com") == [track])
        #expect(store.list(account: "demo").isEmpty)
        #expect(store.folder(account: "a/../b") != store.folder(account: "a"), "an email is a safe folder name")
        store.forget(account: "a@example.com")
        #expect(store.list(account: "a@example.com").isEmpty)
    }

    @Test func hiddenRowsAreTheAccountsAndForgottenOnlyWithTheirRecording() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "recordings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(root: root)
        store.setHidden(["one", "two"], account: "a@example.com")
        #expect(store.hidden(account: "a@example.com") == ["one", "two"])
        #expect(store.hidden(account: "demo").isEmpty)
        store.delete(id: "one", account: "a@example.com")
        #expect(store.hidden(account: "a@example.com") == ["two"], "a deleted or landed recording is forgotten")
        store.forget(account: "a@example.com")
        #expect(store.hidden(account: "a@example.com").isEmpty, "Delete account takes them too")
    }
}