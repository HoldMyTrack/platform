import XCTest

/// The Tracks and Trips panel, end to end against the dev stack: read on the demo, changed
/// only on a fresh account (TestAccount). Skipped where no dev stack answers, as on CI.
final class PanelTests: XCTestCase {
    @MainActor
    func testTheDemoListsItsTracksAndCantChangeThem() throws {
        try LaunchTests.requireDevStack(self)
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
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
        XCTAssertTrue(app.staticTexts["cardDistance"].exists && app.staticTexts["cardMoving"].exists && app.staticTexts["cardPace"].exists, "the stat tiles")
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
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1 checked · '")).firstMatch.exists, "the footer counts the checked")
        app.buttons["endSelecting"].tap()

        app.tabBars.buttons["tabTrips"].tap()
        XCTAssertTrue(app.cells["tripFolder"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["newTrip"].exists, "no +: a Trip is made with Add to trip")
        XCTAssertFalse(app.buttons["tripEdit"].firstMatch.isEnabled, "the demo can't change a Trip")
    }

    @MainActor
    func testEditAndDeleteOnAFreshAccount() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base)
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
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
        // A new type, from the Type picker's search.
        app.buttons["editType"].tap()
        let search = app.searchFields["typeSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Solowheel")
        app.tables["typeList"].staticTexts["Add “Solowheel”"].tap()
        XCTAssertTrue(app.buttons["editType"].staticTexts["Solowheel"].waitForExistence(timeout: 5))
        app.buttons["editSave"].tap()
        XCTAssertTrue(app.staticTexts["Renamed by iOS"].waitForExistence(timeout: 15))

        // Two checked: Edit greys out Name and Description, and says why.
        app.buttons["cardClose"].tap()
        app.buttons["panelHandle"].tap()
        rows.element(boundBy: 0).buttons["rowTile"].tap()
        rows.element(boundBy: 1).buttons["rowTile"].tap()
        app.buttons["barEdit"].tap()
        XCTAssertTrue(app.staticTexts["editMultiNote"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["editName"].isEnabled)
        app.navigationBars.buttons["Cancel"].tap()
        app.buttons["endSelecting"].tap()
        app.staticTexts["Renamed by iOS"].tap()
        XCTAssertTrue(app.otherElements["trackCard"].waitForExistence(timeout: 5))

        // Delete it, confirmed: one row fewer.
        app.buttons["cardDelete"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.otherElements["trackCard"].waitForNonExistence(timeout: 15), "the deleted track's card closes")
        app.buttons["panelHandle"].tap()
        let fewer = NSPredicate(format: "count == %d", listed - 1)
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: fewer, object: rows)], timeout: 15), .completed)
    }

    /// Trips shows its Trip in Normal, with no mode toggle, and the Tracks tab gets its mode back.
    @MainActor
    func testTripsShowNormalAndTheTracksTabKeepsItsMode() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base)
        defer { account.delete() }
        try account.trip("Lakeside")
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        let modes = app.otherElements["modes"]
        app.buttons["modeFog"].tap()
        XCTAssertFalse(app.buttons["panelHandle"].isHittable, "the sheet is Normal mode's")

        app.tabBars.buttons["tabTrips"].tap()
        XCTAssertTrue(app.cells["tripFolder"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(modes.exists, "no mode toggle on Trips")
        XCTAssertTrue(app.staticTexts["By track type"].waitForExistence(timeout: 10), "the open Trip's numbers under its rows")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Trips"
        shot.lifetime = .keepAlways
        add(shot)

        app.tabBars.buttons["tabTracks"].tap()
        XCTAssertTrue(modes.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["modeFog"].isSelected, "Fog again")
    }
}
