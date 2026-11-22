import Testing
@testable import HoldMyTrackCore

/// When a site page counts as left.
struct WebPageExitTests {
    @Test func backDismissAndAnotherTabLeaveThePage() {
        #expect(WebPageExit.left(popped: true, dismissed: false, tabLeft: false, covered: false, onboarding: false))
        #expect(WebPageExit.left(popped: false, dismissed: true, tabLeft: false, covered: false, onboarding: false))
        #expect(WebPageExit.left(popped: false, dismissed: false, tabLeft: true, covered: false, onboarding: false))
    }

    @Test func aScreenOverThePageDoesNotLeaveIt() {
        #expect(!WebPageExit.left(popped: false, dismissed: false, tabLeft: false, covered: true, onboarding: false))
        #expect(!WebPageExit.left(popped: false, dismissed: false, tabLeft: false, covered: false, onboarding: false))
    }

    @Test func firstRunSettingsLeavesTheReadToTheMap() {
        #expect(!WebPageExit.left(popped: false, dismissed: true, tabLeft: false, covered: false, onboarding: true))
    }
}
