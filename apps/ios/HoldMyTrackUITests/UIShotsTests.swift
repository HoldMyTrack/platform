import XCTest

/// A screenshot of every `apps/docs/ui-states.json` entry this app can reach on the demo account,
/// attached under its id for `make ui-compare` to put beside Android's. Runs only when asked
/// (`TEST_RUNNER_HMT_UI_SHOTS=1`), so `make e2e-ios` skips it.
final class UIShotsTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["HMT_UI_SHOTS"] == "1" else { throw XCTSkip("ui-compare only") }
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testA_Default() throws {
        let app = try launch()
        shot("sign-in")
        demo(app)
        let handle = app.buttons["panelHandle"]
        app.tabBars.buttons["tabTracks"].tap()
        heights(app, "tracks")
        half(app)
        let row = app.cells.matching(identifier: "trackRow").firstMatch
        if row.waitForExistence(timeout: 10) {
            row.tap()
            _ = app.otherElements["trackActions"].waitForExistence(timeout: 10)
            settle()
            shot("track-focused")
            app.buttons["barInfo"].tap()
            _ = app.staticTexts["Moving time"].waitForExistence(timeout: 10)
            settle()
            shot("track-info")
            if app.otherElements["trackInfo"].exists { app.navigationBars.buttons.firstMatch.tap() }
            settle()
            if !handle.isHittable || handle.label == "Expand the panel" { half(app) }
            // The focused row's tile: it alone is checked.
            row.buttons["rowTile"].tap()
            _ = app.staticTexts["actionsTarget"].waitForExistence(timeout: 5)
            settle()
            shot("tracks-checked")
            if app.buttons["selectMenu"].exists { PanelTests.uncheckAll(app) }
            settle()
        }

        app.buttons["modeFog"].tap()
        settle(4)
        shot("fog")
        app.buttons["modeFog"].tap()
        settle()
        shot("fog-levels")
        // A tap on the map could open a Fog place's popup; Fog's button closes its menu.
        app.buttons["modeFog"].tap()
        settle()
        app.buttons["modeNormal"].tap()
        settle()

        for (button, name) in [("layers", "layers-menu"), ("places", "places-menu")] {
            app.buttons[button].tap()
            settle()
            shot(name)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
            settle()
        }
        app.buttons["export"].tap()
        _ = app.otherElements["exportViewfinder"].waitForExistence(timeout: 10)
        settle()
        shot("export")
        if app.buttons["exportClose"].exists { app.buttons["exportClose"].tap() }
        settle()

        app.tabBars.buttons["tabTrips"].tap()
        heights(app, "trips")
        half(app)
        let folder = app.cells["tripFolder"].firstMatch
        if folder.waitForExistence(timeout: 10) {
            folder.tap()
            settle()
            shot("trips-folded")
            folder.tap()
        }

        app.tabBars.buttons["tabLibrary"].tap()
        heights(app, "library")
        half(app)
        if app.buttons["librarySync"].waitForExistence(timeout: 5) {
            app.buttons["librarySync"].tap()
            heights(app, "sync")
            if app.buttons["syncBack"].exists { app.buttons["syncBack"].tap() }
        }

        app.tabBars.buttons["tabYou"].tap()
        settle()
        shot("you")
        for (cell, name) in [("youPrivacy", "privacy"), ("youSettings", "settings")] {
            guard app.cells[cell].waitForExistence(timeout: 5) else { continue }
            app.cells[cell].tap()
            settle(name == "settings" ? 6 : 4)
            shot(name)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            settle()
        }
    }

    @MainActor
    func testB_Landscape() throws {
        let app = try launch()
        demo(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        settle(3)
        halves(app, "landscape")
    }

    @MainActor
    func testC_Large() throws {
        let app = try launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"])
        demo(app)
        halves(app, "large")
    }

    // MARK: Steps

    @MainActor
    private func launch(extra: [String] = []) throws -> XCUIApplication {
        try LaunchTests.requireDevStack(self)
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"] + extra
        app.launch()
        _ = app.buttons["demo"].waitForExistence(timeout: 20)
        settle()
        return app
    }

    @MainActor
    private func demo(_ app: XCUIApplication) {
        app.buttons["demo"].tap()
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 20))
        settle(4)
    }

    /// Tracks, Trips and Library half open, then You, each named `<tab>-half-<suffix>`.
    @MainActor
    private func halves(_ app: XCUIApplication, _ suffix: String) {
        for (tab, name) in [("tabTracks", "tracks"), ("tabTrips", "trips"), ("tabLibrary", "library")] {
            app.tabBars.buttons[tab].tap()
            settle(2)
            half(app)
            shot("\(name)-half-\(suffix)")
        }
        app.tabBars.buttons["tabYou"].tap()
        settle()
        shot("you-\(suffix)")
    }

    /// The open tab's sheet closed, half open and open all the way, then half open again.
    @MainActor
    private func heights(_ app: XCUIApplication, _ name: String) {
        settle(2)
        drag(app, toY: 0.98)
        shot("\(name)-collapsed")
        half(app)
        shot("\(name)-half")
        drag(app, toY: 0.02)
        shot("\(name)-expanded")
        drag(app, toY: 0.98)
        half(app)
    }

    /// A drag, not swipeUp, which the grip takes as a tap.
    @MainActor
    private func drag(_ app: XCUIApplication, toY y: CGFloat) {
        let handle = app.buttons["panelHandle"]
        guard handle.waitForExistence(timeout: 5) else { return }
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y)))
        settle()
    }

    @MainActor
    private func half(_ app: XCUIApplication) {
        let handle = app.buttons["panelHandle"]
        if handle.waitForExistence(timeout: 5), handle.label == "Expand the panel" { handle.tap() }
        settle()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func settle(_ seconds: UInt32 = 2) { sleep(seconds) }
}