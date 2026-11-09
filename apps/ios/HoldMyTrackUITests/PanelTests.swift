import XCTest

/// The Activities and Stories panel, end to end against the dev stack: read on the demo, changed
/// only on a fresh account (TestAccount). Skipped where no dev stack answers, as on CI.
final class PanelTests: XCTestCase {
    @MainActor
    func testTheDemoListsItsActivitiesAndCantChangeThem() throws {
        try LaunchTests.requireDevStack(self)
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut"]
        app.launch()
        app.buttons["demo"].tap()
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["rangeLabel"].waitForExistence(timeout: 10))
        app.buttons["panelHandle"].tap()
        let rows = app.cells.matching(identifier: "activityRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))

        // A row's tap focuses it: its card takes the range's place.
        rows.firstMatch.tap()
        XCTAssertTrue(app.otherElements["activityCard"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["cardEdit"].isEnabled, "the demo account can't edit")
        XCTAssertTrue(app.buttons["cardFocus"].isEnabled)
        app.buttons["cardClose"].tap()

        // The tile checks: the selection bar comes, with Delete off for the demo.
        app.buttons["panelHandle"].tap()
        rows.element(boundBy: 0).buttons["rowTile"].tap()
        XCTAssertTrue(app.otherElements["selectionBar"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["barDelete"].isEnabled)
        app.buttons["endSelecting"].tap()

        app.tabBars.buttons["tabStories"].tap()
        XCTAssertTrue(app.cells["storyFolder"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["newStory"].isEnabled)
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
        XCTAssertTrue(app.staticTexts["rangeLabel"].waitForExistence(timeout: 10))
        app.buttons["panelHandle"].tap()
        let rows = app.cells.matching(identifier: "activityRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(rows.count, TestAccount.samples.count)

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
        XCTAssertTrue(app.otherElements["activityCard"].waitForNonExistence(timeout: 15), "the deleted activity's card closes")
        app.buttons["panelHandle"].tap()
        let fewer = NSPredicate(format: "count == %d", TestAccount.samples.count - 1)
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: fewer, object: rows)], timeout: 15), .completed)
    }

    /// Stories shows its Story in Normal, with no mode toggle, and the Map tab gets its mode back.
    @MainActor
    func testStoriesShowNormalAndTheMapTabKeepsItsMode() throws {
        try LaunchTests.requireDevStack(self)
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut"]
        app.launch()
        app.buttons["demo"].tap()
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        let modes = app.segmentedControls["modes"]
        modes.buttons.element(boundBy: 2).tap()
        XCTAssertFalse(app.buttons["panelHandle"].isHittable, "the sheet is Normal mode's")

        app.tabBars.buttons["tabStories"].tap()
        XCTAssertTrue(app.cells["storyFolder"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(modes.exists, "no mode toggle on Stories")

        app.tabBars.buttons["tabMap"].tap()
        XCTAssertTrue(modes.waitForExistence(timeout: 5))
        XCTAssertTrue(modes.buttons.element(boundBy: 2).isSelected, "Heatmap again")
    }
}
