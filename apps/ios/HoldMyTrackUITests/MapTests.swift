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
        // The date range: ‹ moves it back its own length, and a tap on the track brings the
        // nearer knob there.
        let label = app.staticTexts["rangeLabel"]
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        let first = label.label
        app.buttons["shiftEarlier"].tap()
        XCTAssertTrue(waitForChange(of: label, from: first))
        let shifted = label.label
        app.otherElements["scrubber"].coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.35)).tap()
        XCTAssertTrue(waitForChange(of: label, from: shifted))

        app.tabBars.buttons.element(boundBy: 3).tap()
        XCTAssertTrue(app.staticTexts["account"].waitForExistence(timeout: 5))
        app.tabBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.otherElements["map"].exists, "the map keeps its place across a tab switch")
        XCTAssertNotEqual(label.label, first, "the picked range survives a tab switch")
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
