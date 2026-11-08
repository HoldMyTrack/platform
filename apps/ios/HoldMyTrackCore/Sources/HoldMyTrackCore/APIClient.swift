import Foundation

/// Why a call to the API failed.
public enum APIError: Error, Equatable, Sendable {
    /// `426 app_outdated`: the server turns this build away (root docs/IMPLEMENTATION.md §4.33).
    case outdated
    /// Any other answer outside 2xx, with the server's code and its message as sent (ADR-0045),
    /// which the screens show unreworded so the app and the server never disagree.
    case http(status: Int, code: String?, message: String?)
    /// No answer: offline, the server down, or a timeout.
    case unreachable
    /// An answer the app can't read.
    case unreadable

    /// The server's own message, when it sent one.
    public var serverMessage: String? {
        if case .http(_, _, let message) = self, let message, !message.isEmpty { return message }
        return nil
    }
}

/// A document fetched with its ETag, or the word that the one kept is still current.
public enum Fetched: Equatable, Sendable {
    case notModified
    case document(Data, etag: String?)
}

/// An activity as the map frames it.
public struct ActivityRow: Equatable, Sendable {
    public let id: String
    public let startedAt: Date?
    /// `[west, south, east, north]`, or nil for an activity with no track.
    public let bbox: [Double]?
    public let pending: Bool

    public init(id: String, startedAt: Date?, bbox: [Double]?, pending: Bool) {
        self.id = id
        self.startedAt = startedAt
        self.bbox = bbox
        self.pending = pending
    }
}

/// Whether the account's coverage is being redrawn, and the tile version it's at.
public struct CoverageStatus: Equatable, Sendable {
    public let rendering: Bool
    public let tileVersion: String
}

/// A new session: its token and the account it signs in to.
public struct SessionGrant: Equatable, Sendable {
    public let token: String
    public let account: Account
}

/// Which sign-in providers the server has configured (`GET /v1/auth/providers`).
public struct Providers: Equatable, Sendable {
    public let google: Bool
    public let facebook: Bool
    public let apple: Bool

    public static let none = Providers(google: false, facebook: false, apple: false)
}

/// The JSON API, over URLSession with no client library (apps/ios/docs/ARCHITECTURE.md §2).
/// Every request names the build in its User-Agent and asks in the app's language; the session
/// token goes as a bearer header to the API's own origin only. A `426` from any call is reported
/// through onOutdated before the call throws, so no screen has to recognise it.
public final class APIClient: Sendable {
    public let app: AppInfo
    private let language: String
    private let urlSession: URLSession
    private let token: @Sendable () -> String?
    private let onOutdated: @Sendable () -> Void

    public init(
        app: AppInfo,
        language: String,
        session: URLSession = .shared,
        token: @escaping @Sendable () -> String?,
        onOutdated: @escaping @Sendable () -> Void
    ) {
        self.app = app
        self.language = language
        self.urlSession = session
        self.token = token
        self.onOutdated = onOutdated
    }

    // MARK: Sign-in and session

    public func providers() async throws -> Providers {
        let json: ProvidersJSON = try await decode(send("GET", "v1/auth/providers"))
        return Providers(google: json.google, facebook: json.facebook, apple: json.apple)
    }

    public func login(email: String, password: String) async throws -> SessionGrant {
        try await grant(send("POST", "v1/auth/login", body: CredentialsJSON(email: email, password: password, timezone: nil)))
    }

    public func signup(email: String, password: String, timezone: String) async throws -> SessionGrant {
        try await grant(send("POST", "v1/auth/signup", body: CredentialsJSON(email: email, password: password, timezone: timezone)))
    }

    public func demo() async throws -> SessionGrant {
        try await grant(send("POST", "v1/auth/demo"))
    }

    /// Signs in with the authorization code Sign in with Apple gave the app, exchanged by the
    /// server under the app's bundle ID (root docs/IMPLEMENTATION.md §4.9). name is Apple's, sent
    /// on the first authorization only; with timezone, it's for an account the sign-in creates.
    public func apple(code: String, name: String?, timezone: String) async throws -> SessionGrant {
        try await grant(send("POST", "v1/auth/apple/token", body: AppleTokenJSON(authorizationCode: code, name: name, tz: timezone)))
    }

    /// Redeems a browser sign-in's one-time code with the verifier its challenge was made from.
    public func handoff(code: String, verifier: String) async throws -> SessionGrant {
        try await grant(send("POST", "v1/auth/handoff", body: HandoffJSON(code: code, verifier: verifier)))
    }

    /// The signed-in account, which is also the check that a kept token still works.
    public func me() async throws -> Account {
        let json: AccountJSON = try await decode(send("GET", "v1/auth/me"))
        return Account(json)
    }

    /// Ends the session token names on the server. The phone forgets it without waiting
    /// (apps/android/docs/SPEC.md FR-1.3), so the token is passed in rather than read when the
    /// request is built, by which time it's gone.
    public func logout(token: String) async throws {
        var request = request("POST", "v1/auth/logout")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await perform(request)
    }

    /// Mails a fresh verification link; the server's answer, its hourly limit included, is the
    /// message to show.
    public func resendVerification() async throws -> String {
        let json: MessageJSON = try await decode(send("POST", "v1/auth/resend-verification"))
        return json.message
    }

    // MARK: The map

    /// The basemap style, `GET /v1/map/style/{flavor}?lang=`: unauthenticated and the same for
    /// every account, revalidated with the ETag kept from the last fetch.
    public func mapStyle(flavor: String, language: String, etag: String?) async throws -> Fetched {
        try await fetch("v1/map/style/\(flavor)", query: [URLQueryItem(name: "lang", value: language)], etag: etag)
    }

    /// The account's layers document, `GET /v1/map/layers?flavor=` (ADR-0048).
    public func mapLayers(flavor: String, etag: String?) async throws -> Fetched {
        try await fetch("v1/map/layers", query: [URLQueryItem(name: "flavor", value: flavor)], etag: etag)
    }

    /// A page of activity days for the date slider, newest first, before a day if given, with the
    /// account's first activity day.
    public func activityDays(limit: Int, before: String?) async throws -> (days: [String], earliest: String?) {
        var items = [URLQueryItem(name: "days", value: String(limit))]
        if let before { items.append(URLQueryItem(name: "before", value: before)) }
        let json: HistogramJSON = try await decode(send("GET", "v1/activities/histogram", query: items))
        return (json.buckets.map(\.date), json.earliest)
    }

    /// The account's activities, unfiltered or from from to to (YYYY-MM-DD, the account's days).
    public func activities(from: String? = nil, to: String? = nil) async throws -> [ActivityRow] {
        var items: [URLQueryItem] = []
        if let from, let to { items = [URLQueryItem(name: "from", value: from), URLQueryItem(name: "to", value: to)] }
        let json: ActivitiesJSON = try await decode(send("GET", "v1/activities", query: items))
        let iso = ISO8601DateFormatter()
        return json.activities.map { row in
            ActivityRow(id: row.id, startedAt: iso.date(from: row.startedAt), bbox: row.bbox, pending: row.pending)
        }
    }

    public func coverageStatus() async throws -> CoverageStatus {
        let json: CoverageStatusJSON = try await decode(send("GET", "v1/coverage/status"))
        return CoverageStatus(rendering: json.rendering, tileVersion: json.tileVersion)
    }

    /// Prepares a request MapLibre is about to send: the API's own get the session and the app's
    /// headers (authorize); every other, the basemap's and the imagery's, gets the API's Origin,
    /// which the basemap's edge rule and the imagery key check (root docs/IMPLEMENTATION.md §5.4).
    public func prepareMapRequest(_ request: inout URLRequest) {
        guard let url = request.url else { return }
        if ApiOrigin.isAPI(url, base: app.apiBaseURL) {
            authorize(&request)
        } else if let origin = Self.origin(of: app.apiBaseURL) {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
    }

    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private func fetch(_ path: String, query: [URLQueryItem], etag: String?) async throws -> Fetched {
        var request = request("GET", path)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = query
        request.url = components.url
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        // The kept copy is the cache; URLSession's own would answer a revalidation itself.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, http) = try await exchange(request)
        if http.statusCode == 304 { return .notModified }
        try check(http, data)
        return .document(data, etag: http.value(forHTTPHeaderField: "ETag"))
    }

    // MARK: Requests

    /// The request for path on the API, with the app's headers and, since it's the API's own
    /// origin, the session token.
    func request(_ method: String, _ path: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: app.apiBaseURL.appending(path: path), timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        authorize(&request)
        return request
    }

    /// Adds the app's headers, and the token when the request is bound for the API's own origin;
    /// a request anywhere else (the basemap, imagery) gets neither the token nor the headers.
    public func authorize(_ request: inout URLRequest) {
        guard let url = request.url, ApiOrigin.isAPI(url, base: app.apiBaseURL) else { return }
        request.setValue(app.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(language, forHTTPHeaderField: "Accept-Language")
        if let token = token(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    func send(_ method: String, _ path: String, query: [URLQueryItem] = []) async throws -> Data {
        var request = request(method, path)
        if !query.isEmpty, let url = request.url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.queryItems = query
            request.url = c.url
        }
        return try await perform(request)
    }

    func send<Body: Encodable>(_ method: String, _ path: String, body: Body) async throws -> Data {
        guard let data = try? JSONEncoder().encode(body) else { throw APIError.unreadable }
        return try await perform(request(method, path, body: data))
    }

    func perform(_ request: URLRequest) async throws -> Data {
        let (data, http) = try await exchange(request)
        try check(http, data)
        return data
    }

    private func exchange(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.unreadable }
        return (data, http)
    }

    private func check(_ http: HTTPURLResponse, _ data: Data) throws {
        if (200..<300).contains(http.statusCode) { return }
        let failure = try? JSONDecoder().decode(ErrorJSON.self, from: data)
        if http.statusCode == 426 {
            onOutdated()
            throw APIError.outdated
        }
        throw APIError.http(status: http.statusCode, code: failure?.error, message: failure?.message)
    }

    func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw APIError.unreadable }
    }

    private func grant(_ data: Data) throws -> SessionGrant {
        let token: SessionTokenJSON = try decode(data)
        let account: AccountJSON = try decode(data)
        return SessionGrant(token: token.sessionToken, account: Account(account))
    }
}
