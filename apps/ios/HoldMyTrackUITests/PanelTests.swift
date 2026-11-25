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

        // The tile checks: the selection bar comes, its ⋯ with Download on and Delete off for the demo.
        app.buttons["panelHandle"].tap()
        rows.element(boundBy: 0).buttons["rowTile"].tap()
        XCTAssertTrue(app.otherElements["selectionBar"].waitForExistence(timeout: 5))
        app.buttons["barMore"].tap()
        XCTAssertTrue(app.buttons["moreDownload"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["moreDownload"].isEnabled)
        XCTAssertFalse(app.buttons["moreDelete"].isEnabled)
        // Download hands the GPX to the share sheet, Save to Files among its choices.
        app.buttons["moreDownload"].tap()
        XCTAssertTrue(app.cells["Save to Files"].waitForExistence(timeout: 30), "the share sheet")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForNonExistence(timeout: 5))
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
        // A new type, from the Type picker's search. Not one the samples use: the picker lists
        // every type the account has and offers those instead of an Add row.
        app.buttons["editType"].tap()
        let search = app.searchFields["typeSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Paragliding")
        app.tables["typeList"].staticTexts["Add “Paragliding”"].tap()
        XCTAssertTrue(app.buttons["editType"].staticTexts["Paragliding"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertTrue(app.alerts["Discard changes?"].waitForExistence(timeout: 5), "Cancel asks before dropping the fields")
        app.alerts.buttons["Keep editing"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForNonExistence(timeout: 5))
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
        // Route and Photos show dimmed; a tap on Route says why and leaves Track picked.
        let route = app.segmentedControls["editTabs"].buttons["Route"]
        XCTAssertFalse(route.isEnabled)
        XCTAssertFalse(app.staticTexts["editTabBlocked"].exists)
        route.tap()
        XCTAssertTrue(app.staticTexts["editTabBlocked"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["editMultiNote"].exists)
        XCTAssertFalse(app.buttons["panelHandle"].exists, "the Tracks sheet is away while Edit is open")
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
        XCTAssertTrue(app.staticTexts["tripStats"].waitForExistence(timeout: 10), "the open Trip's numbers under its rows")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Trips"
        shot.lifetime = .keepAlways
        add(shot)

        // A tap on the open Trip folds its rows away and back; its numbers stay.
        let folder = app.cells["tripFolder"].firstMatch
        folder.tap()
        XCTAssertEqual(folder.value as? String, "Folded")
        XCTAssertTrue(app.staticTexts["tripStats"].exists, "the numbers stay under a folded Trip")
        folder.tap()
        XCTAssertEqual(folder.value as? String, "Open")

        app.tabBars.buttons["tabTracks"].tap()
        XCTAssertTrue(modes.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["modeFog"].isSelected, "Fog again")
    }

    /// Edit trip and Send a copy are sheets: Save waits for a Name and closes once saved; Send
    /// stays open on "Sent to …" with the field cleared for another address.
    @MainActor
    func testATripIsRenamedAndSentFromSheets() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base)
        defer { account.delete() }
        try account.trip("Lakeside")
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        app.tabBars.buttons["tabTrips"].tap()
        XCTAssertTrue(app.cells["tripFolder"].firstMatch.waitForExistence(timeout: 10))

        app.buttons["tripEdit"].firstMatch.tap()
        let name = app.textFields["tripName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        // Its end, so the caret follows the name: the field may not have focus yet.
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let save = app.buttons["tripSave"]
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Lakeside".count))
        XCTAssertFalse(save.isEnabled, "no Save without a Name")
        name.typeText("Lakeside loop")
        let about = app.textViews["tripDescription"]
        about.tap()
        about.typeText("Two days on the shore.\nBack by the ridge.")
        keep("Edit trip")
        save.tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 10), "the sheet closes once saved")
        XCTAssertTrue(app.cells["tripFolder"].staticTexts["Lakeside loop"].waitForExistence(timeout: 10))

        app.buttons["tripSend"].firstMatch.tap()
        let email = app.textFields["sendEmail"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        email.typeText("nobody@example.com")
        app.buttons["sendCopy"].tap()
        let status = app.staticTexts["sendStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.hasPrefix("Sent to nobody@example.com"))
        XCTAssertEqual(email.value as? String ?? "", "Email", "the field cleared for another address")
        keep("Send a copy")
        app.navigationBars.buttons["Close"].tap()
        XCTAssertTrue(email.waitForNonExistence(timeout: 5))
    }

    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
