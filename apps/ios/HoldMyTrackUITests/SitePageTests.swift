import XCTest

/// The site's pages in the app, end to end against the dev stack. Skipped where no dev stack
/// answers, as on CI.
final class SitePageTests: XCTestCase {
    @MainActor
    func testSettingsOpensSignedInAndCloses() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base, samples: [])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        app.tabBars.buttons["tabYou"].tap()
        app.cells["youSettings"].tap()
        let page = app.webViews["webPage"]
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        // Signed in: the page shows the account's own Settings, not the sign-in form.
        XCTAssertTrue(page.staticTexts.matching(NSPredicate(format: "label ==[c] 'Country'")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(page.buttons["Sign in"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.cells["youSettings"].waitForExistence(timeout: 5))

        // Sync history is a row of the Sync tab.
        app.tabBars.buttons["tabSync"].tap()
        app.cells["syncHistory"].tap()
        XCTAssertTrue(app.webViews["webPage"].waitForExistence(timeout: 10))
    }

    /// A verified account with no Country opens on Settings, with no map behind it.
    @MainActor
    func testTheFirstRunGatesOnSettings() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base, samples: [], country: false)
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        let page = app.webViews["webPage"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["Set up your account"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "no map behind the first run")
        XCTAssertTrue(page.staticTexts.matching(NSPredicate(format: "label ==[c] 'Country'")).firstMatch.waitForExistence(timeout: 15))

        XCTAssertTrue(page.buttons["Save and continue"].exists)
        // Saving reaches the map only where the API is APP_BASE_URL's origin, which the stock dev
        // stack's isn't (docs/DEVELOPMENT.md), so the save itself isn't driven here.
    }

    /// Sync history's View on map opens the native map with that track focused, its day the
    /// range when it was outside it.
    @MainActor
    func testViewOnMapFocusesTheTrack() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base, samples: ["west-side.gpx"])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        app.tabBars.buttons["tabSync"].tap()
        app.cells["syncHistory"].tap()
        let link = app.webViews["webPage"].links["View on map"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        link.tap()
        XCTAssertTrue(app.otherElements["trackCard"].waitForExistence(timeout: 15), "the track is focused on the map")
        XCTAssertTrue(app.tabBars.buttons["tabTracks"].isSelected)
    }
}
