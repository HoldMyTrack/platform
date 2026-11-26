import XCTest

/// Screenshots of every tab at every sheet height, in portrait and landscape, at the default and a
/// large text size, on the demo account, for comparing the layout with Android's by eye. Each is
/// attached as "<text>-<orientation>-<tab>-<height>".
final class LayoutShotsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testDefaultText() throws {
        let app = try launch(extra: [])
        walk(app, text: "default", heights: true)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        walk(app, text: "default", heights: false)
    }

    @MainActor
    func testLargeText() throws {
        let app = try launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        walk(app, text: "large", heights: false)
    }

    @MainActor
    private func launch(extra: [String]) throws -> XCUIApplication {
        try LaunchTests.requireDevStack(self)
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"] + extra
        app.launch()
        app.buttons["demo"].tap()
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 20))
        sleep(4)
        return app
    }

    /// Tracks, Trips, Library and Sync at each sheet height (or half only), then You.
    @MainActor
    private func walk(_ app: XCUIApplication, text: String, heights: Bool) {
        let orientation = XCUIDevice.shared.orientation.isLandscape ? "landscape" : "portrait"
        let handle = app.buttons["panelHandle"]
        func shot(_ name: String) {
            sleep(2)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "\(text)-\(orientation)-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        func drag(toY y: CGFloat) {
            handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y)))
        }
        func atEachHeight(_ tab: String) {
            guard handle.waitForExistence(timeout: 10) else { return shot("\(tab)-nosheet") }
            if !heights {
                if handle.label == "Expand the panel" { handle.tap() }
                return shot("\(tab)-half")
            }
            drag(toY: 0.98)
            shot("\(tab)-collapsed")
            if handle.label == "Expand the panel" { handle.tap() }
            shot("\(tab)-half")
            drag(toY: 0.02)
            shot("\(tab)-expanded")
            drag(toY: 0.98)
            handle.tap()
        }

        app.tabBars.buttons["tabTracks"].tap()
        atEachHeight("tracks")
        app.tabBars.buttons["tabTrips"].tap()
        atEachHeight("trips")
        app.tabBars.buttons["tabLibrary"].tap()
        atEachHeight("library")
        if app.buttons["librarySync"].waitForExistence(timeout: 5) {
            app.buttons["librarySync"].tap()
            atEachHeight("sync")
            if app.buttons["syncBack"].exists { app.buttons["syncBack"].tap() }
        }
        app.tabBars.buttons["tabYou"].tap()
        shot("you")
        app.tabBars.buttons["tabTracks"].tap()
    }
}