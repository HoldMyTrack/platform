import Foundation
import Testing

@testable import HoldMyTrackCore

/// Sending recordings and what follows (apps/ios/docs/SPEC.md FR-5.2).
struct RecordingSyncTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func track(_ id: String, at seconds: TimeInterval = 0, points: Int = 2, sent: Bool = false) -> RecordedTrack {
        RecordedTrack(id: id, startedAt: t0.addingTimeInterval(seconds), endedAt: t0.addingTimeInterval(seconds + 600), movingSeconds: 600, meters: 1000,
                      type: "walking", points: (0..<points).map { RecordedPoint(lat: 41.48, lon: -81.7 + Double($0) * 0.0001, ele: $0 == 0 ? 190 : nil, time: t0.addingTimeInterval(seconds + Double($0) * 3)) },
                      sent: sent)
    }

    @Test func aSentRecordingIsAtWorkThenOnTheMapOrBackOnTheList() {
        #expect(RecordingSync.outcome("a", known: ["a"], processing: ["a"]) == nil)
        #expect(RecordingSync.outcome("a", known: ["a"], processing: []) == .landed)
        #expect(RecordingSync.outcome("a", known: [], processing: []) == .failed)
    }

    @Test func theListIsNewestFirstWithoutTheOnesAwaited() {
        let listed = RecordingSync.listed([track("old", at: 0), track("sent", at: 50, sent: true), track("new", at: 100)])
        #expect(listed.map(\.id) == ["new", "old"])
    }

    @Test func theDemoCantSendAndNothingTickedSendsNothing() {
        #expect(RecordingSync.canSend(ticked: ["a"], isDemo: false))
        #expect(!RecordingSync.canSend(ticked: ["a"], isDemo: true))
        #expect(!RecordingSync.canSend(ticked: [], isDemo: false))
    }

    @Test func aRouteOverTheLimitIsRefusedBeforeSending() {
        #expect(RecordingSync.refusal(track("a", points: RecordingSync.maxPoints)) == nil)
        #expect(RecordingSync.refusal(track("a", points: RecordingSync.maxPoints + 1)) == .tooManyPoints)
    }

    @Test func theRequestCarriesTheRecordingUnderRecorded() {
        var t = track("r1")
        t.name = "Lunch walk"
        let request = RecordingSync.request(t)
        #expect(request.source == "recorded")
        let sent = request.tracks[0]
        #expect(sent.externalID == "r1" && sent.trackType == "walking" && sent.name == "Lunch walk" && sent.description == nil)
        #expect(sent.points.count == 2 && sent.points[0].elevationM == 190 && sent.points[1].elevationM == nil)
        #expect(sent.points[0].time == "2023-11-14T22:13:20.000Z")
    }

    @Test func gpxIsTheRouteWithElevationWhereKnown() {
        let gpx = RecordingSync.gpx(track("r1"), name: "A & B")
        #expect(gpx.contains("<name>A &amp; B</name>"))
        #expect(gpx.contains(#"<trkpt lat="41.48" lon="-81.7"><ele>190.0</ele><time>2023-11-14T22:13:20Z</time></trkpt>"#))
        #expect(gpx.components(separatedBy: "<trkpt").count == 3)
        #expect(gpx.components(separatedBy: "<ele>").count == 2)
    }

    @Test func aFileFromBeforeEditReadsWithNothingSet() throws {
        let old = #"{"id":"r1","startedAt":"2023-11-14T22:13:20Z","endedAt":"2023-11-14T22:23:20Z","movingSeconds":600,"meters":1000,"type":"unknown","points":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let read = try decoder.decode(RecordedTrack.self, from: Data(old.utf8))
        #expect(read.name == nil && read.description == nil && !read.sent)
    }

    @Test func theDefaultTypeIsTheAccountsAndGoesWithIt() {
        let root = FileManager.default.temporaryDirectory.appending(path: "recordings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(root: root)
        #expect(store.defaultType(account: "x") == "unknown")
        store.setDefaultType("hiking", account: "x")
        #expect(store.defaultType(account: "x") == "hiking")
        #expect(store.defaultType(account: "y") == "unknown", "each account's own")
        #expect((try? root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true, "kept out of backups")
        store.forget(account: "x")
        #expect(store.defaultType(account: "x") == "unknown", "forgotten with the account")
    }

    @Test func aDeletedRecordingIsGoneFromItsAccount() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "recordings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(root: root)
        try store.save(track("a"), account: "x")
        try store.save(track("b", at: 10), account: "x")
        store.delete(id: "a", account: "x")
        #expect(store.list(account: "x").map(\.id) == ["b"])
    }
}
