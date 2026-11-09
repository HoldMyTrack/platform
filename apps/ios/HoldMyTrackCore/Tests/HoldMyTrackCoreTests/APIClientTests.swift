import Foundation
import Testing

@testable import HoldMyTrackCore

/// Answers every request from a handler and records what was sent, so the client's headers,
/// bodies and error handling are checked without a server.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Answer {
        var status = 200
        var body = Data()
    }

    nonisolated(unsafe) static var answer: (URLRequest) -> Answer? = { _ in Answer() }
    nonisolated(unsafe) static var sent: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            request.httpBody = data
        }
        Self.sent.append(request)
        guard let answer = Self.answer(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Counts the client's outdated reports.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

@Suite(.serialized)
struct APIClientTests {
    private let app = AppInfo(version: "0.1", commit: "abc1234", build: 42, apiBaseURL: URL(string: "http://localhost:8081")!)
    private let outdated = Counter()

    private func client(token: String? = "tok") -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.sent = []
        let outdated = self.outdated
        return APIClient(app: app, language: "ru", session: URLSession(configuration: config), token: { token }, onOutdated: { outdated.bump() })
    }

    private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private var accountBody: [String: Any] {
        ["email": "ann@example.com", "isDemo": false, "email_verified": true, "display_name": "Ann", "country": "US",
         "timezone": "America/New_York", "locale": "", "avatar_url": "", "unit_system": "imperial"]
    }

    @Test func everyRequestNamesTheBuildTheLanguageAndTheSession() async throws {
        StubProtocol.answer = { _ in .init(body: self.json(self.accountBody)) }
        let account = try await client().me()
        #expect(account.email == "ann@example.com")
        #expect(account.unitSystem == "imperial")
        let sent = try #require(StubProtocol.sent.first)
        #expect(sent.url?.absoluteString == "http://localhost:8081/v1/auth/me")
        #expect(sent.value(forHTTPHeaderField: "User-Agent") == "HoldMyTrack-iOS/0.1 (abc1234; 42)")
        #expect(sent.value(forHTTPHeaderField: "Accept-Language") == "ru")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func noSessionSendsNoAuthorization() async throws {
        StubProtocol.answer = { _ in .init(body: self.json(["google": true, "facebook": false, "apple": false])) }
        let providers = try await client(token: nil).providers()
        #expect(providers == Providers(google: true, facebook: false, apple: false))
        #expect(StubProtocol.sent.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func theTokenNeverLeavesTheAPIsOrigin() {
        let api = client()
        var basemap = URLRequest(url: URL(string: "https://tiles.holdmytrack.com/20261001/basemap.pmtiles")!)
        api.authorize(&basemap)
        #expect(basemap.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(basemap.value(forHTTPHeaderField: "User-Agent") == nil)
        var tile = URLRequest(url: URL(string: "http://localhost:8081/tiles/v1/tracks/4/4/6.mvt")!)
        api.authorize(&tile)
        #expect(tile.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func aSignInSendsTheCredentialsAndReturnsTheTokenAndTheAccount() async throws {
        var body = accountBody
        body["session_token"] = "new-token"
        StubProtocol.answer = { _ in .init(body: self.json(body)) }
        let grant = try await client(token: nil).signup(email: "ann@example.com", password: "hunter22", timezone: "Europe/Tallinn")
        #expect(grant.token == "new-token")
        #expect(grant.account.displayName == "Ann")
        let sent = try #require(StubProtocol.sent.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path == "/v1/auth/signup")
        let credentials = try JSONSerialization.jsonObject(with: try #require(sent.httpBody)) as? [String: String]
        #expect(credentials == ["email": "ann@example.com", "password": "hunter22", "timezone": "Europe/Tallinn"])
    }

    @Test func aLoginLeavesTheTimezoneOut() async throws {
        var body = accountBody
        body["session_token"] = "t"
        StubProtocol.answer = { _ in .init(body: self.json(body)) }
        _ = try await client(token: nil).login(email: "a@b.c", password: "p")
        let credentials = try JSONSerialization.jsonObject(with: try #require(StubProtocol.sent.first?.httpBody)) as? [String: String]
        #expect(credentials == ["email": "a@b.c", "password": "p"])
    }

    @Test func theServersMessageComesBackAsSent() async {
        StubProtocol.answer = { _ in .init(status: 401, body: self.json(["error": "invalid_credentials", "message": "Неверный email или пароль"])) }
        await #expect(throws: APIError.http(status: 401, code: "invalid_credentials", message: "Неверный email или пароль")) {
            _ = try await client(token: nil).login(email: "a@b.c", password: "x")
        }
    }

    @Test func a426IsReportedOnceAndThrown() async {
        StubProtocol.answer = { _ in .init(status: 426, body: self.json(["error": "app_outdated", "message": "Update"])) }
        await #expect(throws: APIError.outdated) { _ = try await client().me() }
        #expect(outdated.value == 1)
    }

    @Test func noAnswerIsUnreachable() async {
        StubProtocol.answer = { _ in nil }
        await #expect(throws: APIError.unreachable) { _ = try await client().me() }
    }

    @Test func anAnswerThatIsntTheContractsIsUnreadable() async {
        StubProtocol.answer = { _ in .init(body: Data("<html>".utf8)) }
        await #expect(throws: APIError.unreadable) { _ = try await client().me() }
    }

    @Test func appleSendsTheCodeTheNameAndTheTimezone() async throws {
        var body = accountBody
        body["session_token"] = "t"
        StubProtocol.answer = { _ in .init(body: self.json(body)) }
        _ = try await client(token: nil).apple(code: "c", name: "Ann Lee", timezone: "Europe/Tallinn")
        let sent = try #require(StubProtocol.sent.first)
        #expect(sent.url?.path == "/v1/auth/apple/token")
        let fields = try JSONSerialization.jsonObject(with: try #require(sent.httpBody)) as? [String: String]
        #expect(fields == ["authorization_code": "c", "name": "Ann Lee", "tz": "Europe/Tallinn"])
    }

    @Test func appleLeavesOutANameItWasntGiven() async throws {
        var body = accountBody
        body["session_token"] = "t"
        StubProtocol.answer = { _ in .init(body: self.json(body)) }
        _ = try await client(token: nil).apple(code: "c", name: nil, timezone: "UTC")
        let fields = try JSONSerialization.jsonObject(with: try #require(StubProtocol.sent.first?.httpBody)) as? [String: String]
        #expect(fields == ["authorization_code": "c", "tz": "UTC"])
    }

    @Test func aMapDocumentIsRevalidatedWithItsETag() async throws {
        StubProtocol.answer = { request in
            request.value(forHTTPHeaderField: "If-None-Match") == "\"e1\"" ? .init(status: 304) : .init(body: Data("{}".utf8))
        }
        let api = client()
        #expect(try await api.mapStyle(flavor: "dark", language: "ru", etag: "\"e1\"") == .notModified)
        let sent = try #require(StubProtocol.sent.first)
        #expect(sent.url?.absoluteString == "http://localhost:8081/v1/map/style/dark?lang=ru")
        guard case .document = try await api.mapLayers(flavor: "dark", etag: nil) else { Issue.record("expected a document"); return }
        #expect(StubProtocol.sent.last?.url?.absoluteString == "http://localhost:8081/v1/map/layers?flavor=dark")
    }

    @Test func mapRequestsCarryTheSessionToTheAPIAndTheOriginElsewhere() {
        let api = client()
        var tile = URLRequest(url: URL(string: "http://localhost:8081/tiles/v1/tracks/4/4/6.mvt")!)
        api.prepareMapRequest(&tile)
        #expect(tile.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(tile.value(forHTTPHeaderField: "Origin") == nil)
        var basemap = URLRequest(url: URL(string: "https://tiles.holdmytrack.com/20261001/basemap.pmtiles")!)
        api.prepareMapRequest(&basemap)
        #expect(basemap.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(basemap.value(forHTTPHeaderField: "Origin") == "http://localhost:8081")
    }

    @Test func activitiesAreReadForFraming() async throws {
        let row: [String: Any] = ["id": "a1", "started_at": "2026-11-03T18:36:33Z", "timezone": "UTC", "activity_type": "walking",
                                  "bbox": [-81.5, 41.2, -81.4, 41.3], "pending": false, "edited": false, "private": false, "stories": []]
        StubProtocol.answer = { _ in .init(body: self.json(["activities": [row]])) }
        let rows = try await client().activities()
        #expect(rows == [ActivityRow(id: "a1", startedAt: Date(timeIntervalSince1970: 1_793_730_993), bbox: [-81.5, 41.2, -81.4, 41.3], pending: false)])
    }

    @Test func trackMetricsAreReadWithTheirBands() async throws {
        let body: [String: Any] = ["activity_id": "a1",
                                   "points": [["lon": 1.5, "lat": 2.5, "speed_mps": 3, "time_s": 0], ["lon": 1.6, "lat": 2.6, "speed_mps": 4, "time_s": 5]],
                                   "bands": [["band": 2, "start": 0, "end": 1]]]
        StubProtocol.answer = { request in
            #expect(request.url?.path == "/v1/activities/a1/track-metrics")
            return .init(body: self.json(body))
        }
        let metrics = try await client().trackMetrics("a1")
        #expect(metrics == TrackMetrics(activityID: "a1", points: [.init(lon: 1.5, lat: 2.5), .init(lon: 1.6, lat: 2.6)], bands: [.init(band: 2, start: 0, end: 1)]))
    }

    @Test func theHandoffSendsTheCodeAndTheVerifier() async throws {
        var body = accountBody
        body["session_token"] = "t"
        StubProtocol.answer = { _ in .init(body: self.json(body)) }
        _ = try await client(token: nil).handoff(code: "c0de", verifier: "v")
        let sent = try JSONSerialization.jsonObject(with: try #require(StubProtocol.sent.first?.httpBody)) as? [String: String]
        #expect(sent == ["code": "c0de", "verifier": "v"])
    }
}
