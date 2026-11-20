import CoreLocation
import XCTest

/// Recording (apps/ios/docs/SPEC.md FR-5.1) on a fresh account. The fixes come from the
/// simulator's simulated location, which the tests walk themselves (walk(for:)).
final class RecordingTests: XCTestCase {
    /// The simulated location, a step north every 2 seconds for seconds, from where the last walk
    /// stopped. A route `simctl location` started is replaced by any earlier test that sets the
    /// location (CaptureTests), and a route that has reached its end gives no fixes.
    @MainActor
    private func walk(for seconds: Int) {
        for _ in 0..<max(1, seconds / 2) {
            Self.step += 1
            XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 41.48 + Double(Self.step) * 0.0001, longitude: -81.70))
            Thread.sleep(forTimeInterval: 2)
        }
    }

    @MainActor private static var step = 0

    /// Walks until status counts a fix, for at most 30 seconds.
    @MainActor
    private func walkToAFix(_ status: XCUIElement) -> Bool {
        let counting = NSPredicate(format: "SELF MATCHES %@", ".*[0-9]:[0-9]{2}:[0-9]{2} · .*")
        for _ in 0..<15 {
            walk(for: 2)
            if status.exists, counting.evaluate(with: status.label) { return true }
        }
        return false
    }

    /// A tap starts, the status counts time and distance, a tap pauses and resumes, a short hold
    /// stops nothing, a stop under a minute keeps nothing, and one past a minute, stopped from the
    /// You tab, opens for naming, is listed on the Sync tab, and once sent lands on the account.
    @MainActor
    func testATapRecordsAndAHoldStopsAndSaves() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base, samples: [])
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
        XCTAssertTrue(walkToAFix(status), "a fix: the clock and the distance")
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
        // Stopped from another tab, it opens for naming on the Sync tab.
        app.tabBars.buttons["tabYou"].tap()
        walk(for: 62)
        record.press(forDuration: 2.6)
        let name = app.textFields["recordingName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "Edit opens on the saved recording")
        name.tap()
        name.typeText("Test walk")
        app.buttons["recordingSave"].tap()
        XCTAssertTrue(app.tabBars.buttons["tabSync"].isSelected)
        let row = app.cells.matching(identifier: "recordingRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.staticTexts["Test walk"].exists, "listed by its name")
        attach("Sync")

        // Ticked and sent, it's on its way, then on the map and off the phone.
        row.buttons["recordingTick"].tap()
        app.buttons["syncSend"].tap()
        XCTAssertTrue(app.staticTexts["syncOnTheirWay"].waitForExistence(timeout: 15), "being added")
        XCTAssertTrue(app.cells["syncEmpty"].waitForExistence(timeout: 90), "landed: it leaves the phone")
        XCTAssertTrue(account.waitForTracks(1, timeout: 10), "the account has it")
    }

    /// A recording the app is killed in comes back on the next launch: Discard, asked twice,
    /// drops it; Resume goes on with its moving time, and Stop saves it, listed on the Sync tab
    /// until a swipe deletes it.
    @MainActor
    func testARecordingTheAppDiesInIsOfferedBack() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base, samples: [])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        let record = app.buttons["record"]
        let status = app.staticTexts["recordStatus"]
        func startAndWaitForAFix() {
            record.tap()
            let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
            if allow.waitForExistence(timeout: 3) { allow.tap() }
            XCTAssertTrue(walkToAFix(status), "a fix")
        }
        func relaunch() -> XCUIElement {
            app.terminate()
            app.launchArguments = ["-hmtTourSeen"]
            app.launch()
            let prompt = app.alerts["Unfinished recording"]
            XCTAssertTrue(prompt.waitForExistence(timeout: 20), "the leftover is asked about")
            return prompt
        }

        startAndWaitForAFix()
        var prompt = relaunch()
        attach("Leftover")
        prompt.buttons["Discard"].tap()
        let confirm = app.alerts["Discard this recording?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.buttons["Discard"].tap()
        XCTAssertTrue(record.waitForLabel("Start recording", timeout: 5))

        startAndWaitForAFix()
        walk(for: 62)
        prompt = relaunch()
        prompt.buttons["Resume"].tap()
        XCTAssertTrue(record.waitForLabel("Pause recording", timeout: 10))
        let pastAMinute = NSPredicate(format: "label CONTAINS '0:01:'")
        XCTAssertTrue(status.wait(for: pastAMinute, timeout: 10), "the moving time goes on from where it was")
        record.press(forDuration: 2.6)
        // Saved, it opens for naming; cancelled, it's listed, and a swipe deletes it, asked first.
        let cancel = app.navigationBars.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        let row = app.cells.matching(identifier: "recordingRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        let confirmDelete = app.alerts["Discard this recording?"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5))
        confirmDelete.buttons["Delete"].tap()
        XCTAssertTrue(app.cells["syncEmpty"].waitForExistence(timeout: 5))
    }

    /// While recording, the Live Activity shows outside the app; its Stop opens the app, which
    /// asks first: Keep recording keeps it, Stop ends it into Edit.
    @MainActor
    func testTheLiveActivitysStopAsksFirst() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base, samples: [])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        let record = app.buttons["record"]
        record.tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(record.waitForLabel("Pause recording", timeout: 10))
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        attach("Live Activity")

        // As the Live Activity's Stop opens it: through the system, to the running app. The test
        // app's own open() would relaunch it.
        func tapStop() {
            XCUIDevice.shared.system.open(URL(string: "holdmytrack://recording/stop")!)
            let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
            if open.waitForExistence(timeout: 3) { open.tap() }
        }
        tapStop()
        let ask = app.alerts["Stop recording?"]
        XCTAssertTrue(ask.waitForExistence(timeout: 10), "Stop asks first")
        ask.buttons["Keep recording"].tap()
        XCTAssertTrue(record.waitForLabel("Pause recording", timeout: 5))
        tapStop()
        XCTAssertTrue(ask.waitForExistence(timeout: 10))
        ask.buttons["Stop"].tap()
        XCTAssertTrue(record.waitForLabel("Start recording", timeout: 5), "stopped")
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