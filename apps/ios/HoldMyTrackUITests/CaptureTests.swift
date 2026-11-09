import CoreLocation
import XCTest

/// Capturing a place (apps/android/docs/SPEC.md FR-2.8) on a fresh account against the dev stack,
/// with the simulator's position moved: away from the place, the banner says how far; inside,
/// 30 seconds of fixes capture it on the server.
final class CaptureTests: XCTestCase {
    @MainActor
    func testWalkingIntoAPlaceCapturesIt() throws {
        try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: TestAccount.base()!, samples: [])
        defer { account.delete() }
        // Around the sample activities, Northfield, Ohio.
        guard let place = try account.place("playground", in: [-81.56, 41.28, -81.48, 41.33]) else {
            throw XCTSkip("no playground in the dev stack's places")
        }
        let device = XCUIDevice.shared
        func move(to point: (lat: Double, lon: Double), jitter: Double = 0) {
            device.location = XCUILocation(location: CLLocation(latitude: point.lat + jitter, longitude: point.lon))
        }
        move(to: place.inside)

        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        app.setPlaygrounds(true)

        // Find my location flies to the place at zoom 14, its badge under the map's centre.
        app.buttons["locate"].tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        sleep(4)
        let map = app.otherElements["map"]
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let capture = app.buttons["spotCapture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 5), "the place's popup offers Capture")

        move(to: place.outside)
        capture.tap()
        let banner = app.otherElements["captureBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertTrue(banner.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' away'")).firstMatch.waitForExistence(timeout: 10))

        // A fix a second inside, as GPS gives them.
        let saved = NSPredicate { _, _ in account.captures().contains(place.id) }
        for second in 0..<45 {
            move(to: place.inside, jitter: second.isMultiple(of: 2) ? 0.000001 : 0)
            if second > 30, saved.evaluate(with: nil) { break }
            sleep(1)
        }
        XCTAssertTrue(account.captures().contains(place.id), "the server has the capture")
        XCTAssertTrue(banner.waitForNonExistence(timeout: 10), "capture ends by itself")
    }
}
