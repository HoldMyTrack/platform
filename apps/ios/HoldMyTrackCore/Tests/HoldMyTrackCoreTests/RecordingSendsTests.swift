import Testing

import HoldMyTrackCore

/// What the shared cases (testdata/client-rules/recording-*.json) don't say of sending recordings.
struct RecordingSendsTests {
    @Test func aRefusalCarriesTheServersReason() {
        #expect(RecordingSends.failure(.http(status: 413, code: nil, message: "why"), afterUnanswered: false) == .refuse(.server("why")))
        #expect(RecordingSends.note(sent: false, sending: false, hidden: false, refusal: .server("why"), isDemo: false) == .refused(.server("why")))
    }
}
