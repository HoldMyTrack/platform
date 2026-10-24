import XCTest

/// The app launches and shows its build; the end-to-end flows join this target as screens land.
final class LaunchTests: XCTestCase {
    @MainActor
    func testLaunchShowsTheBuild() {
        let app = XCUIApplication()
        app.launch()
        let build = app.staticTexts["build"]
        XCTAssertTrue(build.waitForExistence(timeout: 10))
        XCTAssertTrue(build.label.hasPrefix("HoldMyTrack-iOS/"))
    }
}
