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

    @MainActor
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
