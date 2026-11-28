import XCTest

/// The You tab and Upload, end to end against the dev stack on fresh accounts (TestAccount).
/// Skipped where no dev stack answers, as on CI.
final class YouTests: XCTestCase {
    /// A GPX opened in the app, as from Files (the Debug build's -hmtUpload), is listed on Upload
    /// once signed in, sent only on its Upload, and lands as a track.
    @MainActor
    func testAFileOpenedInTheAppIsUploaded() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base, samples: [])
        defer { account.delete() }
        let file = FileManager.default.temporaryDirectory.appending(path: "west-side.gpx")
        try account.sample("west-side.gpx").write(to: file)

        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtUpload", file.path, "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.buttons["chooseFiles"].waitForExistence(timeout: 15), "Upload opens with the file")
        XCTAssertTrue(app.staticTexts["sharedFiles"].label.contains("west-side.gpx"), "listed")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(try account.trackCount(), 0, "nothing is sent unasked")
        // Upload is a sheet over Sync: closed, Sync's own Upload opens it again.
        app.buttons["uploadClose"].tap()
        XCTAssertTrue(app.tables["sync"].waitForExistence(timeout: 5), "Sync under Upload")
        app.buttons["syncUpload"].tap()
        XCTAssertTrue(app.staticTexts["sharedFiles"].waitForExistence(timeout: 5), "still listed after leaving Upload")
        app.buttons["uploadShared"].tap()
        XCTAssertFalse(app.buttons["uploadShared"].isHittable, "the list empties")
        XCTAssertTrue(account.waitForTracks(1, timeout: 90))
        XCTAssertFalse(app.staticTexts["uploadNote"].exists, "nothing refused")
    }

    /// A file's track reaches Library once the server has processed it, with Library showing and
    /// nothing touched meanwhile: the upload's own watch, not a return, reads it again.
    @MainActor
    func testAnUploadThatFinishesProcessingReachesLibrary() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base, samples: [])
        defer { account.delete() }
        let file = FileManager.default.temporaryDirectory.appending(path: "evening-loop.tcx")
        try account.sample("evening-loop.tcx").write(to: file)

        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtUpload", file.path, "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.buttons["uploadShared"].waitForExistence(timeout: 15))
        app.buttons["uploadShared"].tap()
        app.buttons["uploadClose"].tap()
        // Back to Library at once, which reads its page before the file is processed.
        app.tabBars.buttons["tabLibrary"].tap()
        let count = app.staticTexts["libraryCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        // Processed before Library read it, the test can't tell the watch from Library's own read.
        try XCTSkipUnless(count.label.hasPrefix("0"), "processed before Library read its page (\(count.label)): run with the worker paused")
        let one = NSPredicate(format: "label BEGINSWITH '1 '")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: one, object: count)], timeout: 90), .completed, "Library caught up by itself")
    }

    @MainActor
    func testTheYouTabListsItsRowsAndPrivacy() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base, samples: [])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        app.tabBars.buttons["tabYou"].tap()
        XCTAssertTrue(app.staticTexts["account"].waitForExistence(timeout: 10))
        // Android's order: the account over its numbers and recent weeks, Privacy, App, the
        // HoldMyTrack tiles, Sign out and Delete account….
        XCTAssertTrue(app.otherElements["recentWeeks"].waitForExistence(timeout: 10), "the recent weeks")
        XCTAssertTrue(app.staticTexts["Track graph & trends"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "You"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(app.segmentedControls["themeControl"].exists, "Theme inline")
        XCTAssertTrue(app.buttons["youAbout"].exists && app.buttons["youHelp"].exists && app.buttons["youContacts"].exists, "the tiles")
        XCTAssertFalse(app.cells["youSync"].exists, "Sync is Library's, not the You tab's")
        for id in ["youPrivacy", "youTheme", "youLanguage", "youTour"] {
            XCTAssertTrue(app.cells[id].exists, id)
        }
        app.tables["you"].swipeUp()
        for id in ["signOut", "youDelete"] {
            XCTAssertTrue(app.cells[id].waitForExistence(timeout: 5), id)
        }
        app.tables["you"].swipeDown()
        app.cells["youPrivacy"].tap()
        XCTAssertTrue(app.cells["downloadData"].waitForExistence(timeout: 10))
        // What HoldMyTrack keeps sits above Your data, as on Android.
        XCTAssertTrue(app.staticTexts["Nobody else sees your map."].exists)
        app.cells["downloadData"].tap()
        XCTAssertTrue(app.buttons["requestExport"].waitForExistence(timeout: 10), "Download your data, a screen of its own")
    }

    /// Delete account, confirmed by the typed email, signs out; the account is gone.
    @MainActor
    func testDeleteAccountSignsOut() throws {
        let base = try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: base, samples: [])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtTourSeen"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        app.tabBars.buttons["tabYou"].tap()
        // The last row: scrolled to, as a smaller phone needs.
        XCTAssertTrue(app.tables["you"].waitForExistence(timeout: 10))
        app.tables["you"].swipeUp()
        XCTAssertTrue(app.cells["youDelete"].waitForExistence(timeout: 10))
        app.cells["youDelete"].tap()
        let field = app.alerts.textFields["deleteEmail"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // The server judges what's typed, as on Android: Delete is never off, and a wrong email
        // brings the dialog back with the server's refusal, the email kept for correcting.
        let delete = app.alerts.buttons["Delete"]
        XCTAssertTrue(delete.isEnabled)
        let wrong = "nobody@example.com"
        field.typeText(wrong)
        delete.tap()
        // The refusal, which only the dialog shown again holds: the first can linger as it goes.
        let refused = app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "That isn't this account's email address"))
        let shown = NSPredicate(format: "count > 0")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: shown, object: refused)], timeout: 10), .completed, "the server's refusal")
        XCTAssertEqual(field.value as? String, wrong, "what was typed, kept")
        XCTAssertTrue(delete.isHittable, "Delete whole on screen above the keyboard")
        // The dialog shown again has the field in focus, the caret after the kept text. A tap on
        // it would raise the edit menu, which takes the next tap, meant for Delete.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: wrong.count))
        field.typeText(account.email)
        XCTAssertEqual(field.value as? String, account.email)
        // A tap straight after typing can go to the keyboard as it settles: again until it closes.
        for _ in 0..<3 where field.exists {
            delete.tap()
            _ = field.waitForNonExistence(timeout: 3)
        }
        XCTAssertTrue(app.textFields["email"].waitForExistence(timeout: 15), "signed out")
        XCTAssertTrue(app.staticTexts["signInNotice"].exists, "Sign in says the account was deleted")
    }
}
