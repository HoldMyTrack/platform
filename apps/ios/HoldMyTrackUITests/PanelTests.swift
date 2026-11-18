import XCTest

/// The Tracks and Trips panel, end to end against the dev stack: read on the demo, changed
/// only on a fresh account (TestAccount). Skipped where no dev stack answers, as on CI.
final class PanelTests: XCTestCase {
    @MainActor
    func testTheDemoListsItsTracksAndCantChangeThem() throws {
        try LaunchTests.requireDevStack(self)
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut"]
        app.launch()
        app.buttons["demo"].tap()
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        app.buttons["panelHandle"].tap()
        let rows = app.cells.matching(identifier: "trackRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))

        // A row's tap focuses it: its card takes the range's place.
        rows.firstMatch.tap()
        XCTAssertTrue(app.otherElements["trackCard"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["cardEdit"].isEnabled, "the demo account can't edit")
        XCTAssertTrue(app.buttons["cardFocus"].isEnabled)
        // The map draws its pace bands, and the card their legend.
        XCTAssertTrue(app.otherElements["cardBands"].waitForExistence(timeout: 10))
        app.buttons["cardFocus"].tap()
        sleep(2)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Pace bands"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["cardClose"].tap()
        XCTAssertTrue(app.otherElements["cardBands"].waitForNonExistence(timeout: 5))

        // The tile checks: the selection bar comes, with Delete off for the demo.
        app.buttons["panelHandle"].tap()
        rows.element(boundBy: 0).buttons["rowTile"].tap()
        XCTAssertTrue(app.otherElements["selectionBar"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["barDelete"].isEnabled)
        app.buttons["endSelecting"].tap()

        app.tabBars.buttons["tabTrips"].tap()
        XCTAssertTrue(app.cells["tripFolder"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["newTrip"].isEnabled)
    }

    @MainActor
    func testEditAndDeleteOnAFreshAccount() throws {
        try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: try XCTUnwrap(TestAccount.base()))
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        app.buttons["panelHandle"].tap()
        let rows = app.cells.matching(identifier: "trackRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        // The list is the opening view's area, which may not hold every sample.
        let listed = rows.count

        // Edit one: its new name shows on its row.
        rows.firstMatch.tap()
        app.buttons["cardEdit"].tap()
        let name = app.textFields["editName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.press(forDuration: 1)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        name.typeText("Renamed by iOS")
        app.buttons["editSave"].tap()
        XCTAssertTrue(app.staticTexts["Renamed by iOS"].waitForExistence(timeout: 15))

        // Delete it, confirmed: one row fewer.
        app.buttons["cardDelete"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.otherElements["trackCard"].waitForNonExistence(timeout: 15), "the deleted track's card closes")
        app.buttons["panelHandle"].tap()
        let fewer = NSPredicate(format: "count == %d", listed - 1)
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: fewer, object: rows)], timeout: 15), .completed)
    }

    /// Trips shows its Trip in Normal, with no mode toggle, and the Map tab gets its mode back.
    @MainActor
    func testTripsShowNormalAndTheMapTabKeepsItsMode() throws {
        try LaunchTests.requireDevStack(self)
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut"]
        app.launch()
        app.buttons["demo"].tap()
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        let modes = app.segmentedControls["modes"]
        modes.buttons.element(boundBy: 1).tap()
        XCTAssertFalse(app.buttons["panelHandle"].isHittable, "the sheet is Normal mode's")

        app.tabBars.buttons["tabTrips"].tap()
        XCTAssertTrue(app.cells["tripFolder"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(modes.exists, "no mode toggle on Trips")

        app.tabBars.buttons["tabMap"].tap()
        XCTAssertTrue(modes.waitForExistence(timeout: 5))
        XCTAssertTrue(modes.buttons.element(boundBy: 1).isSelected, "Fog again")
    }
}
