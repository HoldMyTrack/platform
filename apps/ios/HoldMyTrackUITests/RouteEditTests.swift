import XCTest

/// The Edit window's Route tab, end to end on a fresh account against the dev stack. Skipped
/// where no dev stack answers, as on CI.
final class RouteEditTests: XCTestCase {
    /// Chop and Undo on the map, then a Chop saved, then a Split saved: a second track.
    @MainActor
    func testAChopAndASplitAreSaved() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base, samples: ["west-side.gpx"])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        openRouteTab(app)

        // The low knob a third of the way: Chop keeps the rest; Undo brings it back.
        let range = app.otherElements["routeRange"]
        XCTAssertTrue(range.waitForExistence(timeout: 15))
        moveLowKnob(range, to: 0.33)
        app.buttons["routeChop"].tap()
        attach("Chopped")
        XCTAssertTrue(app.buttons["routeUndo"].isEnabled)
        app.buttons["routeUndo"].tap()
        XCTAssertFalse(app.buttons["routeUndo"].isEnabled)

        moveLowKnob(range, to: 0.25)
        app.buttons["routeChop"].tap()
        app.buttons["editSave"].tap()
        XCTAssertTrue(app.segmentedControls["editTabs"].waitForNonExistence(timeout: 30))
        XCTAssertNotNil(account.routeEdit(account.ids[0])?["keep"], "the chop is saved")
        XCTAssertTrue(account.waitForTracks(1, timeout: 60), "reprocessed")

        // Split at a knob: two tracks once both parts are processed.
        openRouteTab(app)
        XCTAssertTrue(range.waitForExistence(timeout: 15))
        moveLowKnob(range, to: 0.5)
        app.buttons["routeSplit"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Saving splits'")).firstMatch.exists)
        attach("Split")
        app.buttons["editSave"].tap()
        XCTAssertTrue(app.segmentedControls["editTabs"].waitForNonExistence(timeout: 30))
        XCTAssertTrue(account.waitForTracks(2, timeout: 90), "split in two")
    }

    /// Delete point takes out the point tapped on the map; Move point drags one.
    @MainActor
    func testDeleteAndMoveAPointOnTheMap() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base, samples: ["west-side.gpx"])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        openRouteTab(app)
        XCTAssertTrue(app.otherElements["routeRange"].waitForExistence(timeout: 15))
        sleep(2) // the camera onto the track
        let count = app.staticTexts["routePointCount"]
        let before = count.label

        // A grid of taps over the map above the sheet until one lands on a point.
        app.buttons["routeDeletePoint"].tap()
        let map = app.otherElements["map"]
        var hit: XCUICoordinate?
        // Taps in a row come a third of the map apart, never close enough to be the map's double
        // tap, which would zoom the track away mid-search.
        let grid = Array(stride(from: 0.1, through: 0.9, by: 0.025))
        let third = (grid.count + 2) / 3
        let columns = (0..<third).flatMap { i in [i, i + third, i + 2 * third].filter { $0 < grid.count }.map { grid[$0] } }
        search: for row in stride(from: 0.2, through: 0.45, by: 0.025) {
            for column in columns {
                let at = map.coordinate(withNormalizedOffset: CGVector(dx: column, dy: row))
                at.tap()
                // The map holds a single tap until its double tap can't follow, so the count
                // changes a moment after the tap returns; this tap is the one waited for.
                Thread.sleep(forTimeInterval: 0.5)
                if count.label != before {
                    hit = at
                    break search
                }
            }
        }
        let point = try XCTUnwrap(hit, "a tap on the track deletes a point")
        attach("Deleted")
        // Undo takes each delete back, however many taps landed.
        let undo = app.buttons["routeUndo"]
        var steps = 0
        while undo.isEnabled {
            undo.tap()
            steps += 1
        }
        XCTAssertGreaterThan(steps, 0)
        XCTAssertEqual(count.label, before)

        // The same place pressed and dragged in Move point mode: one step, no point fewer.
        app.buttons["routeMovePoint"].tap()
        point.press(forDuration: 0.2, thenDragTo: point.withOffset(CGVector(dx: 60, dy: 30)))
        XCTAssertTrue(app.buttons["routeUndo"].isEnabled, "the move is a step")
        XCTAssertEqual(count.label, before)
        attach("Moved")
    }

    @MainActor
    private func openRouteTab(_ app: XCUIApplication) {
        let card = app.otherElements["trackCard"]
        if !card.exists {
            app.buttons["panelHandle"].tap()
            let row = app.cells.matching(identifier: "trackRow").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            row.tap()
        }
        let edit = app.buttons["cardEdit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        let enabled = NSPredicate(format: "isEnabled == true")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: edit)], timeout: 60), .completed)
        edit.tap()
        let tabs = app.segmentedControls["editTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        tabs.buttons.element(boundBy: 1).tap()
    }

    /// Drags the low knob from the range's start to fraction of its width.
    @MainActor
    private func moveLowKnob(_ range: XCUIElement, to fraction: Double) {
        let start = range.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: range.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)))
    }

    @MainActor
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
