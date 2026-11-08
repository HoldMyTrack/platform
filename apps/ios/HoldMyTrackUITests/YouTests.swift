import XCTest

/// The You tab and Upload, end to end against the dev stack on fresh accounts (TestAccount).
/// Skipped where no dev stack answers, as on CI.
final class YouTests: XCTestCase {
    /// A GPX opened in the app, as from Files (the Debug build's -hmtUpload), goes to Upload once
    /// signed in and lands as an activity.
    @MainActor
    func testAFileOpenedInTheAppIsUploaded() throws {
        try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: try XCTUnwrap(TestAccount.base()), samples: [])
        defer { account.delete() }
        let file = FileManager.default.temporaryDirectory.appending(path: "west-side.gpx")
        try account.sample("west-side.gpx").write(to: file)

        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut", "-hmtUpload", file.path]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.buttons["chooseFiles"].waitForExistence(timeout: 15), "Upload opens with the file")
        XCTAssertTrue(account.waitForActivities(1, timeout: 90))
        XCTAssertFalse(app.staticTexts["uploadNote"].exists, "nothing refused")
    }

    @MainActor
    func testTheYouTabListsItsRowsAndPrivacy() throws {
        try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: try XCTUnwrap(TestAccount.base()), samples: [])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        app.tabBars.buttons["tabYou"].tap()
        XCTAssertTrue(app.staticTexts["account"].waitForExistence(timeout: 10))
        for id in ["youUpload", "youPrivacy", "youTheme", "youLanguage", "youAbout", "youDelete", "signOut"] {
            XCTAssertTrue(app.cells[id].exists, id)
        }
        app.cells["youPrivacy"].tap()
        XCTAssertTrue(app.cells["downloadData"].waitForExistence(timeout: 10))
        app.cells["downloadData"].tap()
        XCTAssertTrue(app.staticTexts["exportStatus"].waitForExistence(timeout: 10))
    }

    /// Delete account, confirmed by the typed email, signs out; the account is gone.
    @MainActor
    func testDeleteAccountSignsOut() throws {
        try LaunchTests.requireDevStack(self)
        let account = try TestAccount(base: try XCTUnwrap(TestAccount.base()), samples: [])
        defer { account.delete() }
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut"]
        app.launch()
        account.signIn(app)
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        app.tabBars.buttons["tabYou"].tap()
        XCTAssertTrue(app.cells["youDelete"].waitForExistence(timeout: 10))
        app.cells["youDelete"].tap()
        let field = app.alerts.textFields["deleteEmail"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let delete = app.alerts.buttons["Delete account"]
        XCTAssertFalse(delete.isEnabled, "off until the email is typed")
        field.typeText(account.email)
        XCTAssertTrue(delete.isEnabled)
        delete.tap()
        XCTAssertTrue(app.textFields["email"].waitForExistence(timeout: 15), "signed out")
    }
}
