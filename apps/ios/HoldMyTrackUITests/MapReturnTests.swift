import XCTest

/// The map as it comes back, end to end against the dev stack on fresh accounts (TestAccount);
/// skipped where no dev stack answers, as on CI.
final class MapReturnTests: XCTestCase {
    /// A track that arrived while the app was away is there on its return, with no tab switched,
    /// and the empty map's pointer is gone.
    @MainActor
    func testTheAppsReturnReadsTheMapAgain() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base, samples: [])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.buttons["noticeAction"].waitForExistence(timeout: 15), "the empty map points to Sync")

        XCUIDevice.shared.press(.home)
        try account.add("west-side.gpx")
        app.activate()
        XCTAssertTrue(app.buttons["noticeAction"].waitForNonExistence(timeout: 15), "the pointer goes")
        app.buttons["panelHandle"].tap()
        XCTAssertTrue(app.cells.matching(identifier: "trackRow").firstMatch.waitForExistence(timeout: 15), "the track is listed")
    }

    /// The map opens on the account's tracks on every sign-in, the same account's second too.
    @MainActor
    func testASecondSignInOpensOnTheTracks() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base, samples: ["west-side.gpx"])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        let row = app.cells.matching(identifier: "trackRow").firstMatch
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        app.buttons["panelHandle"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 15))

        app.tabBars.buttons["tabYou"].tap()
        XCTAssertTrue(app.staticTexts["account"].waitForExistence(timeout: 10))
        app.tables["you"].swipeUp()
        app.cells["signOut"].tap()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        app.buttons["panelHandle"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the camera is on the track, so the area lists it")
    }
}
