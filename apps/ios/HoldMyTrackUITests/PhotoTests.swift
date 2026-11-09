import XCTest

/// Photos on the map, end to end against the dev stack's demo, whose Stories carry photos.
/// Skipped where no dev stack answers, as on CI.
final class PhotoTests: XCTestCase {
    @MainActor
    func testAStorysPhotoOpensFromItsMarkerAndFullSize() throws {
        try LaunchTests.requireDevStack(self)
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut"]
        app.launch()
        app.buttons["demo"].tap()
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))

        app.tabBars.buttons["tabStories"].tap()
        let story = app.cells.matching(identifier: "storyFolder").containing(.staticText, identifier: "Greater Cleveland trails").firstMatch
        XCTAssertTrue(story.waitForExistence(timeout: 10))
        story.tap()

        // The Story's photos come as markers once the camera is on it; a group zooms in to split.
        let marker = app.buttons.matching(identifier: "photoMarker").firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 15))
        attach("Markers")
        let popup = app.otherElements["photoPopup"]
        for _ in 0..<6 where !popup.exists {
            app.buttons.matching(identifier: "photoMarker").firstMatch.tap()
            sleep(2)
        }
        XCTAssertTrue(popup.waitForExistence(timeout: 5))
        attach("Popup")

        app.buttons["photoFullSize"].tap()
        XCTAssertTrue(app.otherElements["photoViewer"].waitForExistence(timeout: 5))
        sleep(2)
        attach("Viewer")
        app.buttons["viewerZoomIn"].tap()
        XCTAssertTrue(app.buttons["viewerFit"].isEnabled, "zoomed in, Fit is offered")
        app.buttons["viewerClose"].tap()
        XCTAssertTrue(app.otherElements["photoViewer"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(popup.exists, "closing the viewer leaves the popup")

        app.buttons["photoClose"].tap()
        XCTAssertTrue(popup.waitForNonExistence(timeout: 5))
    }

    /// A photo added from the library on a fresh account: placed by the server or by hand,
    /// captioned, saved, still there when the Edit window opens again, then deleted.
    @MainActor
    func testAPhotoAddedThroughSaveSurvivesAReload() throws {
        try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: try XCTUnwrap(TestAccount.base()), samples: ["west-side.gpx"])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        app.buttons["panelHandle"].tap()
        let row = app.cells.matching(identifier: "activityRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        app.buttons["cardEdit"].tap()

        let tabs = app.segmentedControls["editTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        tabs.buttons.element(boundBy: 1).tap()
        let addPhotos = app.buttons["photosAdd"]
        XCTAssertTrue(addPhotos.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForEnabled(addPhotos), "Add photos waits for the track")
        addPhotos.tap()

        // iOS's picker: the library's first photo, then Done.
        let first = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        first.tap()
        app.navigationBars["Photos"].buttons["Done"].tap()

        // Placed by the server, or waiting for the slider.
        let place = app.buttons["photoWaitingPlace"]
        let listed = app.otherElements.matching(identifier: "photoRow").firstMatch
        XCTAssertTrue(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: place),
                                             expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: listed)],
                                       timeout: 30, enforceOrder: false) != .timedOut || place.exists || listed.exists)
        if place.exists {
            app.sliders["photoWaitingSlider"].adjust(toNormalizedSliderPosition: 0.5)
            attach("Waiting")
            place.tap()
        }
        XCTAssertTrue(listed.waitForExistence(timeout: 10))
        app.buttons["photoRowEdit"].firstMatch.tap()
        let caption = app.textFields["photoCaption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        caption.tap()
        caption.typeText("From iOS")
        attach("Draft")
        app.buttons["editSave"].tap()
        XCTAssertTrue(tabs.waitForNonExistence(timeout: 60), "Save closes the window")
        XCTAssertEqual(account.photoCaptions(account.ids[0]), ["From iOS"])

        // Open again: the saved photo is listed.
        app.buttons["cardEdit"].tap()
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        tabs.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts["From iOS"].waitForExistence(timeout: 10))
        attach("Reopened")

        // Delete it through Save: gone from the account.
        app.buttons["photoRowDelete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["photoRowKeep"].waitForExistence(timeout: 5))
        app.buttons["editSave"].tap()
        XCTAssertTrue(tabs.waitForNonExistence(timeout: 30))
        XCTAssertEqual(account.photoCaptions(account.ids[0]), [])
    }

    private func waitForEnabled(_ element: XCUIElement) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)], timeout: 15) == .completed
    }

    @MainActor
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
