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
        modes.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(modes.buttons.element(boundBy: 1).isSelected)
        modes.buttons.element(boundBy: 2).tap()
        modes.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons.element(boundBy: 3).tap()
        XCTAssertTrue(app.staticTexts["account"].waitForExistence(timeout: 5))
        app.tabBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.otherElements["map"].exists, "the map keeps its place across a tab switch")
    }
}
