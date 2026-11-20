import Foundation
import Testing

@testable import HoldMyTrackCore

/// The journal a recording writes as it goes, what it leaves when the app dies, and what the app
/// does with a leftover (apps/ios/docs/SPEC.md FR-5.1).
struct RecordingJournalTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func point(_ lon: Double, _ seconds: TimeInterval, ele: Double? = nil) -> RecordedPoint {
        RecordedPoint(lat: 41.48, lon: lon, ele: ele, time: t0.addingTimeInterval(seconds))
    }

    func journal() throws -> (RecordingJournal, URL) {
        let file = FileManager.default.temporaryDirectory.appending(path: "journal-\(UUID().uuidString)/live.sqlite")
        return (try RecordingJournal(path: file), file)
    }

    @Test func aRecordingThatDiesIsLeftWithItsFixesAndTotals() throws {
        let (journal, file) = try journal()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(journal.leftover() == nil)
        try journal.begin(id: "r1", account: "a@example.com", startedAt: t0)
        try journal.append(point(-81.7, 0, ele: 190.5), id: "r1", moving: 0, meters: 0)
        try journal.append(point(-81.699, 30), id: "r1", moving: 30, meters: 83.4)
        try journal.totals(id: "r1", moving: 42, meters: 83.4)
        // Read back as the next run would, from the file.
        let left = try #require(try RecordingJournal(path: file).leftover())
        #expect(left.id == "r1" && left.account == "a@example.com" && left.startedAt == t0)
        #expect(left.moving == 42 && left.meters == 83.4)
        #expect(left.points == [point(-81.7, 0, ele: 190.5), point(-81.699, 30)])
    }

    @Test func aStopOrANewRecordingLeavesNothingBehind() throws {
        let (journal, file) = try journal()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try journal.begin(id: "r1", account: "a", startedAt: t0)
        try journal.append(point(-81.7, 0), id: "r1", moving: 0, meters: 0)
        try journal.begin(id: "r2", account: "a", startedAt: t0)
        #expect(journal.leftover()?.id == "r2" && journal.leftover()?.points.isEmpty == true)
        try journal.clear()
        #expect(journal.leftover() == nil)
    }

    @Test func aLeftoverResumesPausedWithTheDeadTimeLeftOut() {
        let left = RecordingJournal.Leftover(id: "r1", account: "a", startedAt: t0, moving: 120, meters: 300, points: [point(-81.7, 0), point(-81.699, 120)])
        var r = Recording.restored(left)
        #expect(r.state == .paused && r.id == "r1" && r.points.count == 2)
        #expect(r.moving(at: t0.addingTimeInterval(3600)) == 120, "an hour dead adds nothing")
        r.resume(at: t0.addingTimeInterval(3600))
        let first = r.add(point(-81.6, 3601), accuracy: 5)
        #expect(first && r.meters == 300, "the first fix after it starts afresh")
        let saved = r.finished(at: t0.addingTimeInterval(3610), type: "unknown")
        #expect(saved?.id == "r1", "saved under its own id, so a second save writes the same file")
    }

    @Test func resumingNeedsPreciseLocationAsStartingDoes() {
        #expect(RecordTap.of(.paused, access: .approximate) == .askPrecise)
        #expect(RecordTap.of(.paused, access: .denied) == .refused)
        #expect(RecordTap.of(.paused, access: .notAsked) == .askLocation)
        #expect(RecordTap.of(.paused, access: .precise) == .resume)
    }

    @Test func aLeftoverIsAskedAboutOnlyUnderItsOwnAccount() {
        #expect(LeftoverAction.of(leftover: nil, signedIn: "a", recording: .idle, resumeAsked: false) == .none)
        #expect(LeftoverAction.of(leftover: "a", signedIn: "a", recording: .idle, resumeAsked: false) == .prompt)
        #expect(LeftoverAction.of(leftover: "a", signedIn: "a", recording: .idle, resumeAsked: true) == .resume, "the notification's tap")
        #expect(LeftoverAction.of(leftover: "b", signedIn: "a", recording: .idle, resumeAsked: true) == .wait, "another account's waits for it")
        #expect(LeftoverAction.of(leftover: "a", signedIn: "a", recording: .recording, resumeAsked: false) == .none)
    }
}