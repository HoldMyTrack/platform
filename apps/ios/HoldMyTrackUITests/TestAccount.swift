import XCTest

/// A fresh account on the dev stack, as Android's flows use: signed up with a password, given a
/// Country so it skips the first run, and the three sample activities under `/static/testing/`
/// uploaded and processed. Deleted at the end of the test.
final class TestAccount {
    let email = "ios-flows-\(Int(Date().timeIntervalSince1970 * 1000))@holdmytrack.local"
    let password = "flows-test-password"
    private let base: String
    private let session = URLSession(configuration: .ephemeral)
    private(set) var ids: [String] = []

    static let samples = ["west-side.gpx", "evening-loop.tcx", "mill-creek-falls.fit"]

    /// samples: which of the sample files to upload first.
    /// country false leaves it unset, for the first run.
    init(base: String, samples: [String] = TestAccount.samples, country: Bool = true) throws {
        self.base = base
        try call("POST", "/v1/auth/signup", ["email": email, "password": password])
        if country { try call("PATCH", "/v1/account/settings", ["display_name": "", "country": "US", "timezone": "America/New_York"]) }
        for name in samples { try upload(name, data: try sample(name)) }
        try settle(count: samples.count)
    }

    /// A sample file's bytes, from the dev stack.
    func sample(_ name: String) throws -> Data { try get("/static/testing/\(name)") }

    /// Whether the account has count activities, none Pending, within timeout seconds.
    func waitForActivities(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let json = try? call("GET", "/v1/activities", nil) as? [String: Any]
            let rows = json?["activities"] as? [[String: Any]] ?? []
            if rows.count == count && !rows.contains(where: { $0["pending"] as? Bool == true }) { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    func delete() {
        _ = try? call("DELETE", "/v1/account", ["email": email])
    }

    /// The dev stack the Debug build talks to.
    static func base() -> String? {
        ["http://localhost:8080", "http://localhost:8081"].first { base in
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var ok = false
            URLSession.shared.dataTask(with: URL(string: base + "/healthz")!) { _, response, _ in
                ok = (response as? HTTPURLResponse)?.statusCode == 200
                sem.signal()
            }.resume()
            sem.wait()
            return ok
        }
    }

    /// Signs the app in as this account from the sign-in screen.
    @MainActor
    func signIn(_ app: XCUIApplication) {
        let field = app.textFields["email"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(email)
        let secret = app.secureTextFields["password"]
        secret.tap()
        secret.typeText(password)
        app.buttons["primary"].tap()
        // iOS offers to save the password in a sheet over the app, which takes the next tap.
        let save = app.sheets["Save Password?"]
        if save.waitForExistence(timeout: 8) {
            save.buttons.matching(NSPredicate(format: "label != 'Save'")).firstMatch.tap()
        }
    }

    private func settle(count: Int) throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let json = try call("GET", "/v1/activities", nil) as? [String: Any]
            let rows = json?["activities"] as? [[String: Any]] ?? []
            if rows.count == count && !rows.contains(where: { $0["pending"] as? Bool == true }) {
                ids = rows.compactMap { $0["id"] as? String }
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw NSError(domain: "TestAccount", code: 1, userInfo: [NSLocalizedDescriptionKey: "uploads not settled"])
    }

    private func upload(_ name: String, data: Data) throws {
        let boundary = UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: base + "/v1/activities/upload")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try send(request)
    }

    private func get(_ path: String) throws -> Data {
        try send(URLRequest(url: URL(string: base + path)!))
    }

    @discardableResult
    private func call(_ method: String, _ path: String, _ body: [String: Any]?) throws -> Any? {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data = try send(request)
        return data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
    }

    /// The session cookie the signup set rides along in the ephemeral session's cookie store.
    private func send(_ request: URLRequest) throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Data?, URLResponse?, Error?)
        session.dataTask(with: request) { data, response, error in
            result = (data, response, error)
            sem.signal()
        }.resume()
        sem.wait()
        if let error = result.2 { throw error }
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "TestAccount", code: status, userInfo: [NSLocalizedDescriptionKey: "\(request.httpMethod ?? "") \(request.url!.path): \(status) \(String(decoding: result.0 ?? Data(), as: UTF8.self))"])
        }
        return result.0 ?? Data()
    }
}