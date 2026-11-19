import XCTest

/// The map image export (apps/ios/docs/SPEC.md FR-2.11) on a fresh account with a track.
final class ExportTests: XCTestCase {
    /// The viewfinder opens over the map with the image's size, a preset sets its own, Close puts
    /// the map back, and Capture saves the image to Photos and opens the share sheet.
    @MainActor
    func testTheViewfinderSizesTheImageAndCaptureSavesAndShares() throws {
        try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: try XCTUnwrap(TestAccount.base()), samples: ["west-side.gpx"])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))

        let export = app.buttons["export"]
        XCTAssertTrue(export.waitForExistence(timeout: 10))
        export.tap()
        let size = app.staticTexts["exportSize"]
        XCTAssertTrue(size.waitForExistence(timeout: 5))
        XCTAssertTrue(size.label.hasPrefix("1920 × ") || size.label.hasSuffix(" × 1920"), size.label)
        let modes = app.segmentedControls["modes"]
        XCTAssertFalse(modes.exists && modes.isHittable, "the chrome steps aside")
        // Nothing checked: Show stats says why it can't, under the window.
        app.buttons["exportStats"].tap()
        XCTAssertTrue(app.staticTexts["exportError"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["exportError"].label, "Check tracks to show their stats.")
        app.buttons["exportClose"].tap()
        XCTAssertTrue(app.segmentedControls["modes"].waitForExistence(timeout: 5))
        XCTAssertFalse(size.exists)

        // With tracks checked, Show stats previews the server's card in the window.
        app.buttons["panelHandle"].tap()
        let row = app.cells.matching(identifier: "trackRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.buttons["rowTile"].tap()
        app.buttons["panelHandle"].tap()
        export.tap()
        // Show stats is kept on the phone, so an earlier run may have left it ticked.
        let stats = app.buttons["exportStats"]
        if !stats.isSelected { stats.tap() }
        XCTAssertTrue(app.images["exportStatsCard"].waitForExistence(timeout: 15), "the stats card")
        app.buttons["exportChoice"].tap()
        app.buttons["Instagram · Square"].tap()
        XCTAssertEqual(size.label, "1080 × 1080")
        attach("Viewfinder")

        app.buttons["exportCapture"].tap()
        // iOS asks once for adding to Photos, once the image is made.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 60) { allow.tap() }
        XCTAssertTrue(app.otherElements["exportViewfinder"].waitForNonExistence(timeout: 30), "the image is made")
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10) || app.collectionViews.firstMatch.waitForExistence(timeout: 5), "the share sheet")
        attach("Share sheet")
    }

    @MainActor
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}