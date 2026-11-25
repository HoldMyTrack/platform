import Foundation
import Testing

import HoldMyTrackCore

/// Which recordings send themselves and what their rows say (apps/android/docs/SPEC.md FR-5.2).
struct RecordingSendsTests {
    private func track(_ id: String, sent: Bool = false) -> RecordedTrack {
        RecordedTrack(id: id, startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 600),
                      movingSeconds: 600, meters: 1000, type: "walk", points: [], sent: sent)
    }

    private func toSend(hidden: Set<String> = [], held: Set<String> = [], refused: Set<String> = [], retry: Bool = false) -> [String] {
        RecordingSends.toSend([track("a", sent: true), track("b"), track("c")], hidden: hidden, held: held, refused: refused, retry: retry).map(\.id)
    }

    @Test func onlyAVerifiedRealAccountSends() {
        #expect(RecordingSends.sends(emailVerified: true, isDemo: false))
        #expect(!RecordingSends.sends(emailVerified: true, isDemo: true))
        #expect(!RecordingSends.sends(emailVerified: false, isDemo: false))
    }

    @Test func whatsOnItsWayIsNeverSentTwiceAndARefusalOnlyOnRetry() {
        #expect(toSend() == ["b", "c"])
        #expect(toSend(refused: ["b"]) == ["c"])
        #expect(toSend(refused: ["b"], retry: true) == ["b", "c"])
    }

    @Test func oneSwipedAsideIsNeverSentAndSaysNothing() {
        #expect(toSend(hidden: ["b"]) == ["c"])
        #expect(toSend(hidden: ["b"], retry: true) == ["c"])
        #expect(RecordingSends.note(sent: false, sending: false, hidden: true, refusal: .tooManyPoints, isDemo: false) == nil)
    }

    @Test func onlyAFailureEveryRecordingWouldMeetStopsTheSend() {
        func http(_ status: Int) -> RecordingSends.Failure { RecordingSends.failure(.http(status: status, code: nil, message: "why")) }
        #expect(RecordingSends.failure(.unreachable) == .stop && RecordingSends.failure(.outdated) == .stop)
        #expect(http(401) == .stop && http(403) == .stop && http(429) == .stop)
        #expect(http(413) == .refuse(.server("why")) && http(400) == .refuse(.server("why")))
        #expect(http(500) == .next && http(408) == .next && RecordingSends.failure(.unreadable) == .next)
    }

    @Test func oneOpenOnTheSaveScreenIsNeverSentFromUnderIt() {
        #expect(toSend(held: ["c"]) == ["b"])
        #expect(toSend(held: ["c"], retry: true) == ["b"])
    }

    @Test func retryShowsWhileARealAccountHasRecordingsNotSent() {
        #expect(RecordingSends.retryShown(isDemo: false, unsent: 2))
        #expect(!RecordingSends.retryShown(isDemo: false, unsent: 0))
        #expect(!RecordingSends.retryShown(isDemo: true, unsent: 2))
    }

    @Test func aRowSaysItsOnItsWayGoingRefusedOrWaiting() {
        #expect(RecordingSends.note(sent: true, sending: false, hidden: false, refusal: nil, isDemo: false) == .processing)
        #expect(RecordingSends.note(sent: false, sending: true, hidden: false, refusal: .tooManyPoints, isDemo: false) == .sending)
        #expect(RecordingSends.note(sent: false, sending: false, hidden: false, refusal: .server("too short"), isDemo: false) == .refused(.server("too short")))
        #expect(RecordingSends.note(sent: false, sending: false, hidden: false, refusal: nil, isDemo: false) == .waiting)
        #expect(RecordingSends.note(sent: false, sending: false, hidden: false, refusal: nil, isDemo: true) == nil)
    }
}
