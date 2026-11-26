import XCTest

/// Library (apps/docs/SPEC.md FR-4.1), end to end against the dev stack on the demo
/// account. Skipped where no dev stack answers, as on CI.
final class LibraryTests: XCTestCase {
    @MainActor
    func testTheDemoFindsATrackOpensItAndReachesSync() throws {
        try LaunchTests.requireDevStack(self)
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        app.buttons["demo"].tap()
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))

        // Every track, counted, the first page listed.
        app.tabBars.buttons["tabLibrary"].tap()
        let rows = app.tables["libraryList"].cells.matching(identifier: "trackRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let count = app.staticTexts["libraryCount"]
        XCTAssertTrue(count.label.hasSuffix("tracks"), "the count: \(count.label)")
        let reset = app.buttons["libraryReset"]
        XCTAssertFalse(reset.exists && reset.isHittable, "no filter, no Reset")

        // A search that matches nothing says so; Reset brings every track back.
        let search = app.textFields["librarySearch"]
        search.tap()
        search.typeText("zzzz-no-such-track")
        XCTAssertTrue(app.staticTexts["libraryEmpty"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["libraryEmpty"].label.contains("zzzz-no-such-track"))
        XCTAssertTrue(reset.isHittable, "the sheet rose above the keyboard")
        reset.tap()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))

        // Checking a row offers Download; the demo has no Delete.
        rows.firstMatch.buttons["rowTile"].tap()
        XCTAssertTrue(app.buttons["libraryDownload"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["libraryDelete"].exists)
        app.buttons["libraryUncheck"].tap()

        // A row opens on the Tracks tab, focused.
        rows.firstMatch.tap()
        XCTAssertTrue(app.otherElements["trackCard"].waitForExistence(timeout: 15), "the track focused on the map")
        XCTAssertTrue(app.tabBars.buttons["tabTracks"].isSelected)

        // + opens Sync in Library's place; ‹ and a tap on the tab go back.
        app.openSync()
        app.buttons["syncBack"].tap()
        XCTAssertTrue(app.buttons["librarySync"].waitForExistence(timeout: 5))
        app.buttons["librarySync"].tap()
        XCTAssertTrue(app.tables["sync"].waitForExistence(timeout: 5))
        app.tabBars.buttons["tabLibrary"].tap()
        XCTAssertTrue(app.buttons["librarySync"].waitForExistence(timeout: 5), "the tab again goes back to Library")
    }
}
