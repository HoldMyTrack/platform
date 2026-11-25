import XCTest

/// The map as it comes back, end to end against the dev stack on fresh accounts (TestAccount);
/// skipped where no dev stack answers, as on CI.
final class MapReturnTests: XCTestCase {
    /// A track that arrived while the app was away is there on its return, with no tab switched,
    /// and the empty map's pointer is gone.
    @MainActor
    func testTheAppsReturnReadsTheMapAgain() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base, samples: [])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.buttons["noticeAction"].waitForExistence(timeout: 15), "the empty map points to Sync")

        XCUIDevice.shared.press(.home)
        try account.add("west-side.gpx")
        app.activate()
        XCTAssertTrue(app.buttons["noticeAction"].waitForNonExistence(timeout: 15), "the pointer goes")
        app.buttons["panelHandle"].tap()
        XCTAssertTrue(app.cells.matching(identifier: "trackRow").firstMatch.waitForExistence(timeout: 15), "the track is listed")
        app.buttons["panelHandle"].tap()
        sleep(3)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Returned"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// A track that arrived while a map with tracks was away is drawn on its return, its area's
    /// tiles already loaded without it.
    @MainActor
    func testTheAppsReturnDrawsTheNewTrack() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base, samples: ["west-side.gpx"])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        sleep(5)
        let before = trackPixels("Before")
        XCUIDevice.shared.press(.home)
        // The same track a day later and a little south, in the same view.
        try account.add("south.gpx", data: shifted(try account.sample("west-side.gpx")))
        app.activate()
        let deadline = Date().addingTimeInterval(30)
        var after = trackPixels("After")
        while after < before * 3 / 2, Date() < deadline {
            sleep(2)
            after = trackPixels("After")
        }
        XCTAssertGreaterThan(after, before * 3 / 2, "the second track is drawn")
    }

    /// A GPX moved 0.012 degrees south, its times moved to a year that differs.
    private func shifted(_ gpx: Data) throws -> Data {
        var text = String(decoding: gpx, as: UTF8.self)
        let lat = try NSRegularExpression(pattern: "lat=\"([0-9.]+)\"")
        for match in lat.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let range = Range(match.range(at: 1), in: text)!
            text.replaceSubrange(range, with: String(Double(text[range])! - 0.012))
        }
        let year = try NSRegularExpression(pattern: "<time>20[0-9]{2}")
        text = year.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "<time>2019")
        return Data(text.utf8)
    }

    /// How many pixels of the map, left of the rail and above the sheet, are the tracks' color.
    @MainActor
    private func trackPixels(_ name: String) -> Int {
        attach(name)
        guard let image = XCUIScreen.main.screenshot().image.cgImage else { return 0 }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = 0
        for y in height / 5 ..< height * 4 / 5 {
            for x in 0 ..< width * 3 / 4 {
                let i = (y * width + x) * 4
                if abs(Int(bytes[i]) - 0xb0) < 14, abs(Int(bytes[i + 1]) - 0x7e) < 14, abs(Int(bytes[i + 2]) - 0x2e) < 14 { count += 1 }
            }
        }
        return count
    }

    @MainActor
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The map opens on the account's tracks on every sign-in, the same account's second too.
    @MainActor
    func testASecondSignInOpensOnTheTracks() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base, samples: ["west-side.gpx"])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        let row = app.cells.matching(identifier: "trackRow").firstMatch
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        app.buttons["panelHandle"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 15))

        app.tabBars.buttons["tabYou"].tap()
        XCTAssertTrue(app.staticTexts["account"].waitForExistence(timeout: 10))
        app.tables["you"].swipeUp()
        app.cells["signOut"].tap()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        app.buttons["panelHandle"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the camera is on the track, so the area lists it")
    }
}
