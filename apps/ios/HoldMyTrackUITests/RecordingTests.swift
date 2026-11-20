import XCTest

/// Recording (apps/ios/docs/SPEC.md FR-5.1) on a fresh account. The fixes come from the
/// simulator's simulated location, so a route has to be moving first:
/// `xcrun simctl location booted start --speed=5 41.4800,-81.7000 41.4900,-81.6800`.
final class RecordingTests: XCTestCase {
    /// A tap starts, the status counts time and distance, a tap pauses and resumes, a short hold
    /// stops nothing, a stop under a minute keeps nothing, and one past a minute is saved.
    @MainActor
    func testATapRecordsAndAHoldStopsAndSaves() throws {
        try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: try XCTUnwrap(TestAccount.base()), samples: [])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))

        let record = app.buttons["record"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        XCTAssertEqual(record.label, "Start recording")
        record.tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        XCTAssertTrue(record.waitForLabel("Pause recording", timeout: 10))
        XCTAssertFalse(app.segmentedControls["modes"].exists, "the map shows only the recording")

        let status = app.staticTexts["recordStatus"]
        let counting = NSPredicate(format: "label MATCHES %@", ".*[0-9]:[0-9]{2}:[0-9]{2} · .*")
        XCTAssertTrue(status.wait(for: counting, timeout: 30), "a fix: the clock and the distance")
        attach("Recording")

        record.tap()
        XCTAssertTrue(record.waitForLabel("Resume recording", timeout: 5))
        XCTAssertTrue(status.label.contains("Paused"), status.label)
        record.tap()
        XCTAssertTrue(record.waitForLabel("Pause recording", timeout: 5))

        record.press(forDuration: 1)
        XCTAssertTrue(record.waitForLabel("Pause recording", timeout: 2), "a short hold stops nothing")

        record.press(forDuration: 2.6)
        XCTAssertTrue(record.waitForLabel("Start recording", timeout: 5))
        XCTAssertTrue(app.staticTexts["Too short — not saved."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["modes"].waitForExistence(timeout: 5), "the map comes back")

        record.tap()
        XCTAssertTrue(record.waitForLabel("Pause recording", timeout: 10))
        Thread.sleep(forTimeInterval: 62)
        record.press(forDuration: 2.6)
        XCTAssertTrue(app.staticTexts["Recording saved on this phone."].waitForExistence(timeout: 5))
    }

    @MainActor
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

private extension XCUIElement {
    func waitForLabel(_ label: String, timeout: TimeInterval) -> Bool {
        wait(for: NSPredicate(format: "label == %@", label), timeout: timeout)
    }

    func wait(for predicate: NSPredicate, timeout: TimeInterval) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }
}