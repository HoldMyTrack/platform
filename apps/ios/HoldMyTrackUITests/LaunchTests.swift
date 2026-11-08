import XCTest

/// The app's own flows, end to end. Those that need a server run against the dev stack the Debug
/// build talks to, and skip where none answers, as on CI.
final class LaunchTests: XCTestCase {
    private func launchSignedOut() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-hmtSignedOut"]
        app.launch()
        return app
    }

    @MainActor
    func testWithNoSessionTheAppOpensOnSignIn() {
        let app = launchSignedOut()
        XCTAssertTrue(app.textFields["email"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.secureTextFields["password"].exists)
        XCTAssertFalse(app.buttons["primary"].isEnabled, "Sign in waits for both fields")
    }

    @MainActor
    func testTheDemoSignsInAndSignOutReturnsToSignIn() throws {
        try Self.requireDevStack(self)
        let app = launchSignedOut()
        let demo = app.buttons["demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        demo.tap()
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))

        // A relaunch keeps the session and confirms it before showing the account.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.otherElements["map"].waitForExistence(timeout: 15))
        app.tabBars.buttons.element(boundBy: 3).tap()
        XCTAssertTrue(app.staticTexts["account"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["build"].label.contains("commit"))

        app.buttons["signOut"].tap()
        XCTAssertTrue(app.textFields["email"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testTheServersMessageShowsAsSent() throws {
        try Self.requireDevStack(self)
        let app = launchSignedOut()
        let email = app.textFields["email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("nobody-\(UUID().uuidString.prefix(8))@example.com")
        let password = app.secureTextFields["password"]
        password.tap()
        password.typeText("wrong-password")
        app.buttons["primary"].tap()
        let error = app.staticTexts["signInError"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertFalse(error.label.isEmpty)
    }

    /// Skips unless a dev stack answers on one of the ports a Debug build talks to: compose's
    /// default, or the one Config/Local.xcconfig.example suggests.
    @MainActor
    static func requireDevStack(_ test: XCTestCase) throws {
        let answered = ["http://localhost:8080", "http://localhost:8081"].contains { base in
            let done = test.expectation(description: base)
            nonisolated(unsafe) var ok = false
            URLSession.shared.dataTask(with: URL(string: base + "/healthz")!) { _, response, _ in
                ok = (response as? HTTPURLResponse)?.statusCode == 200
                done.fulfill()
            }.resume()
            test.wait(for: [done], timeout: 5)
            return ok
        }
        try XCTSkipUnless(answered, "no dev stack on localhost")
    }
}
