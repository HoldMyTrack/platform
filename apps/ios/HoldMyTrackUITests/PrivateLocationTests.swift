import XCTest

/// The Private location editor on the map, end to end on a fresh account against the dev stack.
/// Skipped where no dev stack answers, as on CI.
final class PrivateLocationTests: XCTestCase {
    /// Add opens the editor on the map; a new circle is saved with its name and radius, opens
    /// again from its row, and is deleted there.
    @MainActor
    func testAPrivateLocationIsAddedOnTheMapAndDeleted() throws {
        try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: try XCTUnwrap(TestAccount.base()), samples: ["west-side.gpx"])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))

        openPrivacy(app)
        app.buttons["addLocation"].tap()
        let editor = app.otherElements["locationEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["panelHandle"].isHittable, "the card takes the sheet's place")
        let name = app.textFields["locationName"]
        name.tap()
        name.typeText("Home\n")
        app.sliders["locationRadius"].adjust(toNormalizedSliderPosition: 0.2)
        // The handle sits in the middle of the map left showing; dragging it moves the circle.
        let map = app.otherElements["map"]
        let top = app.segmentedControls["modes"].frame.maxY, bottom = editor.frame.minY
        let handle = map.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: map.frame.midX, dy: (top + bottom) / 2))
        handle.press(forDuration: 0.1, thenDragTo: handle.withOffset(CGVector(dx: 40, dy: 30)))
        attach("New Private location")
        app.buttons["locationSave"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 15))
        let saved = account.privateLocations()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?["name"] as? String, "Home")
        let radius = saved.first?["radius_m"] as? Int ?? 0
        XCTAssertTrue(radius > 200 && radius % 10 == 0, "the slider's radius, in 10 m steps: \(radius)")

        openPrivacy(app)
        let row = app.cells["privateLocation"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["locationSave"].isEnabled, "nothing changed yet")
        app.buttons["locationDelete"].tap()
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 15))
        XCTAssertTrue(account.privateLocations().isEmpty)
    }

    @MainActor
    private func openPrivacy(_ app: XCUIApplication) {
        // A tap while the map is still settling after sign-in can be lost: once more if so.
        app.tabBars.buttons["tabYou"].tap()
        if !app.staticTexts["account"].waitForExistence(timeout: 5) { app.tabBars.buttons["tabYou"].tap() }
        let privacy = app.cells["youPrivacy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 10))
        privacy.tap()
    }

    @MainActor
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}