import XCTest

/// The map, end to end against the dev stack, on the demo account; skipped where no dev stack
/// answers, as on CI.
final class MapTests: XCTestCase {
    @MainActor
    func testTheDemoOpensOnTheMapAndSwitchesModes() throws {
        try LaunchTests.requireDevStack(self)
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut"]
        app.launch()
        let demo = app.buttons["demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        demo.tap()
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        let modes = app.segmentedControls["modes"]
        XCTAssertTrue(modes.exists)
        // Fog and Heatmap name what they cover, since neither takes the date range; Normal
        // doesn't. The level notice fades within seconds, which the query can miss.
        let chip = app.staticTexts["modeChip"]
        modes.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(modes.buttons.element(boundBy: 1).isSelected)
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        attach("Fog")
        let fogChip = chip.label
        modes.buttons.element(boundBy: 2).tap()
        XCTAssertTrue(waitForChange(of: chip, from: fogChip))
        attach("Heatmap")
        modes.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(chip.waitForNonExistence(timeout: 5))
        // Dates: picking a day in To's calendar sets the button, and Clear dates puts it back.
        app.buttons["panelHandle"].tap()
        let dates = app.buttons["datesFilter"]
        XCTAssertTrue(dates.waitForExistence(timeout: 10))
        let unset = dates.value as? String
        dates.tap()
        app.buttons["datesBefore"].tap()
        let calendar = app.datePickers["datesCalendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 5))
        // A day other than the one the calendar opens on, which a tap wouldn't change.
        calendar.buttons.matching(NSPredicate(format: "label MATCHES '.*day, [A-Za-z]+ [0-9]+' AND isEnabled == true AND isSelected == false")).firstMatch.tap()
        XCTAssertTrue(app.buttons["datesBeforeClear"].waitForExistence(timeout: 5), "To is set")
        app.buttons["datesClear"].tap()
        XCTAssertTrue(app.buttons["datesBeforeClear"].waitForNonExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertEqual(dates.value as? String, unset)

        app.tabBars.buttons.element(boundBy: 3).tap()
        XCTAssertTrue(app.staticTexts["account"].waitForExistence(timeout: 5))
        app.tabBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.otherElements["map"].exists, "the map keeps its place across a tab switch")
    }

    /// Points of interest on the demo's own area: a picked category counts on the Layers badge,
    /// and below the tiles' zoom "Show in this area" loads its places and says how many.
    @MainActor
    func testAPickedCategoryShowsItsPlacesInTheArea() throws {
        try LaunchTests.requireDevStack(self)
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut"]
        app.launch()
        app.buttons["demo"].tap()
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        let layers = app.buttons["layers"]
        app.setPlaygrounds(false)
        let before = layers.label
        app.setPlaygrounds(true)
        XCTAssertNotEqual(layers.label, before, "the badge counts the pick")
        let area = app.buttons["showInArea"]
        XCTAssertTrue(area.waitForExistence(timeout: 10))
        area.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'showInArea' AND label CONTAINS ':'")).firstMatch.waitForExistence(timeout: 10))
        app.setPlaygrounds(false)
        XCTAssertTrue(area.waitForNonExistence(timeout: 5))
        XCTAssertEqual(layers.label, before)
    }

    @MainActor
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func waitForChange(of element: XCUIElement, from old: String) -> Bool {
        let changed = NSPredicate(format: "label != %@", old)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: changed, object: element)], timeout: 5) == .completed
    }
}


extension XCUIApplication {
    /// Ticks or unticks Playgrounds in the Layers menu, whatever an earlier test left: the pick is
    /// kept on the phone.
    @MainActor
    func setPlaygrounds(_ on: Bool) {
        buttons["layers"].tap()
        let item = buttons["Playgrounds"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        if item.isSelected == on {
            // The menu closes on a tap outside it.
            otherElements["map"].coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.6)).tap()
        } else {
            item.tap()
        }
    }
}