import XCTest

/// The tour, its offer and the first-time cards (apps/android/docs/SPEC.md FR-2.12), from a phone that
/// has shown none of them (-hmtTourReset).
final class TourTests: XCTestCase {
    /// The demo gets the tour unasked: every step to Done, which puts the Tracks tab and Normal back;
    /// Take a tour on the You tab starts it again, and Skip ends it.
    @MainActor
    func testTheDemoTakesTheWholeTourAndCanTakeItAgain() throws {
        try LaunchTests.requireDevStack(self)
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourReset"]
        app.launch()
        app.buttons["demo"].tap()
        let progress = app.staticTexts["tourProgress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 20), "the demo's tour starts by itself")
        XCTAssertEqual(progress.label, "1 of 15")
        let next = app.buttons["tourNext"]
        for step in 2...15 {
            next.tap()
            XCTAssertTrue(app.staticTexts["\(step) of 15"].waitForExistence(timeout: 10), "step \(step)")
            if step == 6 || step == 14 || step == 15 { attach("Tour step \(step)") }
            if step == 14 {
                XCTAssertTrue(app.tabBars.buttons["tabSync"].isSelected, "Sync's step is on the Sync tab")
                XCTAssertTrue(app.tables["sync"].exists, "with its sheet open")
            }
        }
        XCTAssertTrue(app.cells["youTour"].exists, "the last step is on the You tab")
        next.tap()
        XCTAssertTrue(app.otherElements["tourCard"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons.element(boundBy: 0).isSelected, "the Tracks tab comes back")
        XCTAssertTrue(app.buttons["modeNormal"].isSelected, "Normal comes back")

        // A page over Sync's map, Sync history here, gives way for the Sync step's sheet.
        app.tabBars.buttons["tabSync"].tap()
        app.cells["syncHistory"].tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10))
        app.tabBars.buttons["tabYou"].tap()
        app.cells["youTour"].tap()
        XCTAssertTrue(app.staticTexts["1 of 15"].waitForExistence(timeout: 10))
        for step in 2...14 {
            next.tap()
            XCTAssertTrue(app.staticTexts["\(step) of 15"].waitForExistence(timeout: 10), "again, step \(step)")
        }
        XCTAssertTrue(app.tables["sync"].exists, "Sync's step is on the sheet, the page gone")
        app.buttons["tourSkip"].tap()
        XCTAssertTrue(app.otherElements["tourCard"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["tabYou"].isSelected, "Skip puts the user back where the tour started")
    }

    /// An account with tracks is offered the tour; Not now declines it, and Fog and the Trips tab
    /// each earn their card once.
    @MainActor
    func testAnAccountIsOfferedTheTourAndEarnsEachCardOnce() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base, samples: ["west-side.gpx"])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourReset"]
        app.launch()
        account.signIn(app)
        let title = app.staticTexts["tourTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the offer")
        XCTAssertEqual(title.label, "New here?")
        // A pick meanwhile leaves the offer up until it's answered.
        let fog = app.buttons["modeFog"]
        fog.tap()
        XCTAssertEqual(title.label, "New here?")
        app.buttons["tourSkip"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))

        app.buttons["modeNormal"].tap()
        fog.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Fog's card")
        XCTAssertEqual(title.label, "Fog of War")
        attach("Fog card")
        app.buttons["tourNext"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        app.buttons["modeNormal"].tap()
        fog.tap()
        XCTAssertFalse(title.waitForExistence(timeout: 2), "a card shows once")

        app.tabBars.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the Trips card")
        XCTAssertEqual(title.label, "Trips")
        // A tap outside a card closes it and reaches the app.
        app.tabBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons.element(boundBy: 0).isSelected)
    }

    @MainActor
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}