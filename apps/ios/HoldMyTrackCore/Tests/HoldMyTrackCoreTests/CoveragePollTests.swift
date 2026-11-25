import Testing

import HoldMyTrackCore

struct CoveragePollTests {
    @Test func itSlowsAfterThreeMinutes() {
        #expect(CoveragePoll.delay(polls: 0) == .seconds(2))
        #expect(CoveragePoll.delay(polls: 89) == .seconds(2))
        #expect(CoveragePoll.delay(polls: 90) == .seconds(10))
    }
}
