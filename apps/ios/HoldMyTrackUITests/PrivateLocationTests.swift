import XCTest

/// The Private location editor on the map, end to end on a fresh account against the dev stack.
/// Skipped where no dev stack answers, as on CI.
final class PrivateLocationTests: XCTestCase {
    /// Add opens the editor on the map; a new circle is saved with its name and radius, opens
    /// again from its row, and is deleted there.
    @MainActor
    func testAPrivateLocationIsAddedOnTheMapAndDeleted() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base, samples: ["west-side.gpx"])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))

        openPrivacy(app)
        app.cells["addLocation"].tap()
        let editor = app.otherElements["locationEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["panelHandle"].isHittable, "the editor takes the sheet's place")
        let name = app.textFields["locationName"]
        name.tap()
        name.typeText("Home")
        // The header rides on the keyboard, and in landscape the fields scroll under it.
        XCTAssertTrue(app.buttons["locationSave"].isHittable, "Save above the keyboard")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["locationSave"].waitForHittable(timeout: 5), "Save above the keyboard in landscape")
        XCTAssertTrue(name.isHittable, "Name on screen in landscape")
        attach("Landscape with the keyboard")
        XCUIDevice.shared.orientation = .portrait
        // The handle's drag below is worked out from the map's frame: portrait first.
        let portrait = NSPredicate { _, _ in app.windows.firstMatch.frame.height > app.windows.firstMatch.frame.width }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: portrait, object: nil)], timeout: 5), .completed)
        name.typeText("\n")
        app.sliders["locationRadius"].adjust(toNormalizedSliderPosition: 0.2)
        // The handle sits in the middle of the map left showing; dragging it moves the circle.
        let map = app.otherElements["map"]
        let top = app.otherElements["modes"].frame.maxY, bottom = editor.frame.minY
        let handle = map.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: map.frame.midX, dy: (top + bottom) / 2))
        handle.press(forDuration: 0.1, thenDragTo: handle.withOffset(CGVector(dx: 40, dy: 30)))
        attach("New private location")
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
        attach("Privacy")
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
extension XCUIElement {
    /// Whether it can be tapped within timeout seconds, as after a rotation settles.
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists && isHittable { return true }
            usleep(250_000)
        }
        return exists && isHittable
    }
}
