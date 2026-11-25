import Foundation
import Testing

import HoldMyTrackCore

/// Which recordings send themselves and what their rows say (apps/android/docs/SPEC.md FR-5.2).
struct RecordingSendsTests {
    private func track(_ id: String, sent: Bool = false) -> RecordedTrack {
        RecordedTrack(id: id, startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 600),
                      movingSeconds: 600, meters: 1000, type: "walk", points: [], sent: sent)
    }

    private func toSend(hidden: Set<String> = [], held: Set<String> = [], refused: Set<String> = [], setBack: [String] = [], retry: Bool = false) -> [String] {
        RecordingSends.toSend([track("a", sent: true), track("b"), track("c")], hidden: hidden, held: held, refused: refused, setBack: setBack, retry: retry).map(\.id)
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
        func http(_ status: Int) -> RecordingSends.Failure { RecordingSends.failure(.http(status: status, code: nil, message: "why"), afterUnanswered: false) }
        #expect(RecordingSends.failure(.outdated, afterUnanswered: false) == .stop)
        for status in [401, 403, 404, 421, 429, 503] { #expect(http(status) == .stop) }
        for status in [400, 413, 422] { #expect(http(status) == .refuse(.server("why"))) }
        #expect(http(500) == .next)
        #expect(RecordingSends.failure(.unreadable, afterUnanswered: true) == .next)
    }

    @Test func oneRequestWithNoAnswerMayBeTheRecordingsTwoInARowAreTheConnections() {
        let silent: [APIError] = [.unreachable] + [408, 502, 504].map { .http(status: $0, code: nil, message: nil) }
        for error in silent {
            #expect(RecordingSends.unanswered(error))
            #expect(RecordingSends.failure(error, afterUnanswered: false) == .next)
            #expect(RecordingSends.failure(error, afterUnanswered: true) == .stop)
        }
        #expect(!RecordingSends.unanswered(.unreadable) && !RecordingSends.unanswered(.http(status: 500, code: nil, message: nil)))
    }

    @Test func whatFailedGoesLast() {
        #expect(toSend(setBack: ["b"]) == ["c", "b"])
        #expect(toSend(setBack: ["c", "b"]) == ["c", "b"], "the latest last, so the order turns")
    }

    @Test func deleteLeavesWhatsGoingAndSaysWhatLanded() {
        #expect(RecordingSends.deletion(track("a"), sending: false, landed: false) == .deleted)
        #expect(RecordingSends.deletion(track("a"), sending: true, landed: false) == .sending)
        #expect(RecordingSends.deletion(track("a", sent: true), sending: false, landed: false) == .sending)
        #expect(RecordingSends.deletion(nil, sending: false, landed: true) == .landed)
        #expect(RecordingSends.deletion(nil, sending: false, landed: false) == .deleted, "gone by an earlier Delete")
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
