import XCTest

/// The map, end to end against the dev stack, on a fresh account with the sample tracks
/// (TestAccount); skipped where no dev stack answers, as on CI.
final class MapTests: XCTestCase {
    @MainActor
    func testTheMapOpensAndSwitchesModes() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base)
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        let modes = app.otherElements["modes"]
        XCTAssertTrue(modes.exists)
        // The rail down the right edge, top to bottom.
        let rail = ["layers", "places", "locate", "export"].map { app.buttons[$0] }
        XCTAssertTrue(rail.allSatisfy(\.exists))
        XCTAssertEqual(rail.map(\.frame.minY), rail.map(\.frame.minY).sorted(), "Layers, Places, Find my location, export")
        app.buttons["modeFog"].tap()
        XCTAssertTrue(app.buttons["modeFog"].isSelected)
        attach("Fog")
        app.buttons["modeNormal"].tap()
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

        app.tabBars.buttons["tabYou"].tap()
        XCTAssertTrue(app.staticTexts["account"].waitForExistence(timeout: 5))
        app.tabBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.otherElements["map"].exists, "the map keeps its place across a tab switch")
    }

    /// Places around the sample tracks: a picked category counts on the Places badge,
    /// and below the tiles' zoom "Show in this area" loads its places and says how many.
    @MainActor
    func testAPickedCategoryShowsItsPlacesInTheArea() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base)
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        let places = app.buttons["places"]
        let layers = app.buttons["layers"].label
        app.setPlaygrounds(false)
        let before = places.label
        app.setPlaygrounds(true)
        XCTAssertNotEqual(places.label, before, "the badge counts the pick")
        XCTAssertEqual(app.buttons["layers"].label, layers, "places count on their own button")
        let area = app.buttons["showInArea"]
        XCTAssertTrue(area.waitForExistence(timeout: 10))
        area.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'showInArea' AND label CONTAINS ':'")).firstMatch.waitForExistence(timeout: 10))
        app.setPlaygrounds(false)
        XCTAssertTrue(area.waitForNonExistence(timeout: 5))
        XCTAssertEqual(places.label, before)
    }

    /// An account with nothing on the map is pointed to Sync, as on Android: the notice's Sync
    /// opens the Sync tab.
    @MainActor
    func testAnEmptyMapPointsToSync() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base, samples: [])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        let sync = app.buttons["noticeAction"]
        XCTAssertTrue(sync.waitForExistence(timeout: 15), "the empty map's notice offers Sync")
        sync.tap()
        let tab = app.tabBars.buttons["tabSync"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: tab)
        XCTAssertEqual(XCTWaiter().wait(for: [selected], timeout: 5), .completed, "Sync opens the Sync tab")
    }

    /// Fog's level control over the sample tracks: its segment names the level, the menu offers Auto and
    /// each level, a picked level holds, and a tap on a place names it in a popup.
    @MainActor
    func testFogsLevelMenuLocksALevelAndATapNamesAPlace() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base)
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        // Fog names its level once the layers document has them; a tap on it while it's on opens the menu.
        let level = app.buttons["modeFog"]
        level.tap()
        let named = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS ' · '"), object: level)
        XCTAssertEqual(XCTWaiter().wait(for: [named], timeout: 10), .completed, level.label)
        level.tap()
        // A row reads its count after its name.
        func item(_ title: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch }
        let auto = item("Auto")
        XCTAssertTrue(auto.waitForExistence(timeout: 10))
        attach("Fog level menu")
        // A country may have its own word for its regions.
        let region = item("State").exists ? "State" : "Region"
        item(region).tap()
        XCTAssertTrue(level.label.contains(region), level.label)
        app.otherElements["map"].tap()
        XCTAssertTrue(app.otherElements["fogPlacePopup"].waitForExistence(timeout: 5))
        attach("Fog place")
        level.tap()
        XCTAssertTrue(auto.waitForExistence(timeout: 10))
        auto.tap()
        XCTAssertFalse(level.label.contains("Locked"), level.label)
    }

    @MainActor
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}


extension XCUIApplication {
    /// Ticks or unticks Playgrounds in the Places menu, whatever an earlier test left: the pick is
    /// kept on the phone.
    @MainActor
    func setPlaygrounds(_ on: Bool) {
        buttons["places"].tap()
        let item = buttons["Playgrounds"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        if item.isSelected != on { item.tap() }
        // The menu stays open for more picks, and closes on a tap outside it.
        otherElements["map"].coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.6)).tap()
        XCTAssertTrue(item.waitForNonExistence(timeout: 5))
    }
}