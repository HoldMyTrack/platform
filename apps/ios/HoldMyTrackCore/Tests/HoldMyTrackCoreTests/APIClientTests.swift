import Foundation
import Testing

@testable import HoldMyTrackCore

/// Answers every request from a handler and records what was sent, so the client's headers,
/// bodies and error handling are checked without a server.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Answer {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
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
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"].merging(answer.headers) { $1 })!
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
    private let app = AppInfo(version: "0.1.0", commit: "abc1234", build: 42, apiBaseURL: URL(string: "http://localhost:8081")!)
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
        #expect(sent.url?.absoluteString == "http://localhost:8081/v2/auth/me")
        #expect(sent.value(forHTTPHeaderField: "User-Agent") == "HoldMyTrack-iOS/0.1.0 (abc1234; 42)")
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

    /// The server reads a session cookie before the bearer token, so a cookie kept from another
    /// account would outrank the token: no request to the API sends or keeps one.
    @Test func theSessionGoesOnlyAsTheBearerToken() async throws {
        let api = client()
        _ = try? await api.me()
        #expect(StubProtocol.sent.first?.httpShouldHandleCookies == false)
        var tile = URLRequest(url: URL(string: "http://localhost:8081/tiles/v1/tracks/4/4/6.mvt")!)
        api.prepareMapRequest(&tile)
        #expect(tile.httpShouldHandleCookies == false)
        #expect(api.uploadRequest(boundary: "b").httpShouldHandleCookies == false)
        var basemap = URLRequest(url: URL(string: "https://tiles.holdmytrack.com/20261001/basemap.pmtiles")!)
        api.prepareMapRequest(&basemap)
        #expect(basemap.httpShouldHandleCookies, "another origin's requests are left alone")
    }

    @Test func theCookiesKeptForTheAPIAreForgotten() throws {
        // One store for every run, emptied before and after, so the runs leave nothing behind.
        let jar = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: "hmt-tests")
        jar.removeCookies(since: .distantPast)
        defer { jar.removeCookies(since: .distantPast) }
        let other = URL(string: "https://tiles.holdmytrack.com/")!
        for url in [app.apiBaseURL, other] {
            jar.setCookies(HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": "holdmytrack_session=stale; Path=/"], for: url), for: url, mainDocumentURL: nil)
        }
        try #require(jar.cookies(for: app.apiBaseURL)?.count == 1, "the API's cookie is kept to begin with")
        client().forgetCookies(in: jar)
        #expect(jar.cookies(for: app.apiBaseURL)?.isEmpty ?? true)
        #expect(jar.cookies(for: other)?.count == 1)
    }

    @Test func aSignInSendsTheCredentialsAndReturnsTheTokenAndTheAccount() async throws {
        var body = accountBody
        body["session_token"] = "new-token"
        StubProtocol.answer = { _ in .init(body: self.json(body)) }
        let grant = try await client(token: nil).login(email: "ann@example.com", password: "hunter22")
        #expect(grant.token == "new-token")
        #expect(grant.account.displayName == "Ann")
        let sent = try #require(StubProtocol.sent.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path == "/v2/auth/login")
        let credentials = try JSONSerialization.jsonObject(with: try #require(sent.httpBody)) as? [String: String]
        #expect(credentials == ["email": "ann@example.com", "password": "hunter22"])
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
        #expect(sent.url?.path == "/v2/auth/apple/token")
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
        #expect(sent.url?.absoluteString == "http://localhost:8081/v2/map/style/dark?lang=ru")
        guard case .document = try await api.mapLayers(flavor: "dark", etag: nil) else { Issue.record("expected a document"); return }
        #expect(StubProtocol.sent.last?.url?.absoluteString == "http://localhost:8081/v2/map/layers?flavor=dark")
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


    @Test func trackMetricsAreReadWithTheirBands() async throws {
        let body: [String: Any] = ["track_id": "a1",
                                   "points": [["lon": 1.5, "lat": 2.5, "speed_mps": 3, "time_s": 0], ["lon": 1.6, "lat": 2.6, "speed_mps": 4, "time_s": 5]],
                                   "bands": [["band": 2, "start": 0, "end": 1]]]
        StubProtocol.answer = { request in
            #expect(request.url?.path == "/v2/tracks/a1/route-metrics")
            return .init(body: self.json(body))
        }
        let metrics = try await client().trackMetrics("a1")
        #expect(metrics == RouteMetrics(trackID: "a1", points: [.init(lon: 1.5, lat: 2.5, time: 0), .init(lon: 1.6, lat: 2.6, time: 5)], bands: [.init(band: 2, start: 0, end: 1)]))
    }

    @Test func spotsInAreaSendTheBoxAndTheCategories() async throws {
        let spot: [String: Any] = ["id": 7, "category": "monument", "name": "Soldiers", "lon": -81.5, "lat": 41.2]
        StubProtocol.answer = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(request.url?.path == "/v2/spots")
            #expect(items.first { $0.name == "bbox" }?.value == "-81.60000,41.10000,-81.40000,41.30000")
            #expect(items.first { $0.name == "categories" }?.value == "monument,dog_park")
            return .init(body: self.json(["spots": [spot], "total": 12]))
        }
        let found = try await client().spotsInArea(west: -81.6, south: 41.1, east: -81.4, north: 41.3, categories: [.monument, .dogPark])
        #expect(found.spots == [Spot(id: 7, category: "monument", name: "Soldiers", lon: -81.5, lat: 41.2)])
        #expect(found.total == 12)
    }

    @Test func capturesAreReadSinceATimeWithOrWithoutFractions() async throws {
        StubProtocol.answer = { request in
            let since = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "since" }?.value
            #expect(since == "1970-01-01T00:01:40.000Z")
            return .init(body: self.json(["captures": [["spot_id": 7, "captured_at": "2026-11-03T18:36:33Z"],
                                                       ["spot_id": 8, "captured_at": "2026-11-03T18:36:33.5Z"]]]))
        }
        let captures = try await client().spotCaptures(since: Date(timeIntervalSince1970: 100))
        #expect(captures == [7: Date(timeIntervalSince1970: 1_793_730_993), 8: Date(timeIntervalSince1970: 1_793_730_993.5)])
    }

    @Test func aPlacesAreaIsReadAsLatLonRings() async throws {
        StubProtocol.answer = { _ in .init(body: self.json([
            "id": 7, "category": "monument", "lon": 1.5, "lat": 2.5,
            "area": ["type": "MultiPolygon", "coordinates": [[[[1, 2], [1, 3], [2, 3], [1, 2]]]]],
        ])) }
        let area = try await client().spotArea(7)
        #expect(area == [[[GeoPoint(lat: 2, lon: 1), GeoPoint(lat: 3, lon: 1), GeoPoint(lat: 3, lon: 2), GeoPoint(lat: 2, lon: 1)]]])
    }

    @Test func aCaptureSendsThePositionAndReadsTheAnswer() async throws {
        StubProtocol.answer = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/v2/spots/7/captures")
            return .init(status: 201, body: self.json(["spot_id": 7, "captured_at": "2026-11-03T18:36:33Z"]))
        }
        #expect(await client().captureSpot(7, at: GeoPoint(lat: 2.5, lon: 1.5)) == .saved(spotID: 7, at: Date(timeIntervalSince1970: 1_793_730_993)))
        StubProtocol.answer = { _ in .init(status: 422, body: self.json(["error": "outside"])) }
        #expect(await client().captureSpot(7, at: GeoPoint(lat: 0, lon: 0)) == .outside)
    }

    @Test func aTripsPhotosAreAskedForByTrip() async throws {
        StubProtocol.answer = { _ in .init(body: self.json(["photos": [[
            "id": "p1", "track_id": "a1", "taken_at": "2026-10-04T15:00:00Z", "route_at": "2026-10-04T15:00:00Z",
            "timezone": "America/New_York", "lon": -81.7, "lat": 41.5, "caption": NSNull(), "width": 2048, "height": 1536,
            "url": "/v2/photos/p1/image", "thumb_url": "/v2/photos/p1/thumb",
        ]]])) }
        let photos = try await client().photos(.trip("s1"))
        #expect(StubProtocol.sent.first?.url?.absoluteString == "http://localhost:8081/v2/photos?trip=s1")
        #expect(photos == [Photo(id: "p1", trackID: "a1", takenAt: "2026-10-04T15:00:00Z", routeAt: "2026-10-04T15:00:00Z",
                                 timezone: "America/New_York", lon: -81.7, lat: 41.5, width: 2048, height: 1536,
                                 url: "/v2/photos/p1/image", thumbURL: "/v2/photos/p1/thumb")])
    }

    @Test func thePlaceCheckSendsTheZonedTimeAloneAndReadsNeedsPlace() async throws {
        StubProtocol.answer = { _ in .init(body: self.json(["route_at": "2026-10-04T15:00:00Z", "taken_at": NSNull()])) }
        let exif = PhotoExif(takenAt: Date(timeIntervalSince1970: 1_791_126_000), takenLocal: "2026-10-04T11:00:00", lat: 41.5, lon: -81.7)
        #expect(try await client().checkPhotoPlace(trackID: "a1", exif: exif) == .at(1_791_126_000))
        let sent = try JSONSerialization.jsonObject(with: try #require(StubProtocol.sent.first?.httpBody)) as? [String: Any]
        #expect(sent?["taken_at"] as? String == "2026-10-04T15:00:00Z")
        #expect(sent?["taken_local"] == nil)
        StubProtocol.answer = { _ in .init(status: 422, body: self.json(["error": "photo_needs_place", "message": "?"])) }
        #expect(try await client().checkPhotoPlace(trackID: "a1", exif: PhotoExif()) == .needsPlace)
    }

    @Test func anUploadIsMultipartWithBothImagesAndThePlace() async throws {
        StubProtocol.answer = { _ in .init(status: 201, body: self.json([
            "id": "p1", "track_id": "a1", "taken_at": NSNull(), "route_at": "2026-10-04T15:00:00Z", "timezone": "UTC",
            "lon": 1, "lat": 2, "caption": "Lake", "width": 10, "height": 10, "url": "/u", "thumb_url": "/t",
        ])) }
        let prepared = PreparedPhoto(file: Data("FILE".utf8), thumb: Data("THUMB".utf8), exif: PhotoExif(takenLocal: "2026-10-04T11:00:00"))
        let photo = try await client().uploadPhoto(trackID: "a1", photo: prepared, routeAt: 1_791_126_000, caption: "Lake")
        #expect(photo.caption == "Lake")
        let sent = try #require(StubProtocol.sent.first)
        #expect(sent.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = String(decoding: try #require(sent.httpBody), as: UTF8.self)
        for part in ["name=\"track_id\"\r\n\r\na1", "name=\"file\"; filename=\"photo.jpg\"\r\nContent-Type: image/jpeg\r\n\r\nFILE",
                     "name=\"thumb\"; filename=\"thumb.jpg\"", "name=\"taken_local\"\r\n\r\n2026-10-04T11:00:00",
                     "name=\"route_at\"\r\n\r\n2026-10-04T15:00:00Z", "name=\"caption\"\r\n\r\nLake"] {
            #expect(body.contains(part), "\(part)")
        }
        #expect(!body.contains("name=\"lat\""))
        #expect(body.hasSuffix("--\r\n"))
    }

    @Test func trackPointsAreReadWithTheSavedEdit() async throws {
        StubProtocol.answer = { _ in .init(body: self.json([
            "points": [[10, 50, 1000], [10.1, 50.1, 2000]],
            "edit": ["keep": [1000, 2000], "move": ["2000": [10.2, 50.2]]],
        ])) }
        let read = try await client().trackPoints("a1")
        #expect(StubProtocol.sent.first?.url?.path == "/v2/tracks/a1/route-points")
        #expect(read.points == [RoutePoint(lon: 10, lat: 50, t: 1000), RoutePoint(lon: 10.1, lat: 50.1, t: 2000)])
        #expect(read.edit == RouteEdit(keep: TimeSpan(1000, 2000), move: [2000: [10.2, 50.2]]))
    }

    @Test func aRouteEditSendsTheWholeEditAndReadsASplitIntoAPrivateLocation() async throws {
        StubProtocol.answer = { _ in .init(status: 202) }
        #expect(try await client().saveRouteEdit("a1", edit: RouteEdit(drop: [5]), splitAt: 7, allowHidden: false) == .queued)
        let sent = try JSONSerialization.jsonObject(with: try #require(StubProtocol.sent.first?.httpBody)) as? [String: Any]
        #expect(sent?["split_at"] as? Int == 7)
        #expect((sent?["edit"] as? [String: Any])?["drop"] as? [Int] == [5])
        #expect(sent?["allow_hidden"] == nil)
        StubProtocol.answer = { _ in .init(status: 422, body: self.json(["error": "split_hides_part", "message": "The second part is private."])) }
        #expect(try await client().saveRouteEdit("a1", edit: nil, splitAt: 7, allowHidden: false) == .splitHidesPart("The second part is private."))
    }

    @Test func theAreaListSendsTheViewAndDatesAndReadsTheTotal() async throws {
        let row: [String: Any] = ["id": "a1", "started_at": "2026-11-03T18:36:33Z", "timezone": "UTC", "track_type": "walking", "name": NSNull(),
                                  "distance_meters": 1200.5, "moving_seconds": 600, "bbox": [-81.5, 41.2, -81.4, 41.3], "pending": false, "private": false, "trips": []]
        StubProtocol.answer = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(request.url?.path == "/v2/tracks/area")
            #expect(items.first { $0.name == "bbox" }?.value == "-81.6,41.1,-81.4,41.3")
            #expect(items.first { $0.name == "from" }?.value == "2026-06-03")
            #expect(items.first { $0.name == "to" } == nil)
            return .init(body: self.json(["tracks": [row], "types": [:], "total": 1500]))
        }
        let read = try await client().areaList(box: [-81.6, 41.1, -81.4, 41.3], dates: DateFilter(after: "2026-06-03"))
        #expect(read.tracks.map(\.id) == ["a1"])
        #expect(read.tracks.first?.description == nil)
        #expect(read.total == 1500)
    }

    @Test func aLibraryPageSendsItsQueryAndReadsTheBounds() async throws {
        let row: [String: Any] = ["id": "a1", "started_at": "2026-11-03T18:36:33Z", "timezone": "UTC", "track_type": "walking", "name": NSNull(),
                                  "distance_meters": 1200.5, "moving_seconds": 600, "description": NSNull(), "bbox": NSNull(), "pending": false,
                                  "edited": false, "private": false, "route_edit": NSNull(), "photos": NSNull(), "trips": []]
        let bounds: [String: Any] = ["min_distance_meters": 800, "max_distance_meters": 42000, "first_date": "2024-03-01", "last_date": "2026-11-03",
                                     "types": [["type": "walking", "count": 7], ["type": "cycling", "count": 2]]]
        StubProtocol.answer = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(request.url?.path == "/v2/tracks")
            #expect(items.map(\.name) == ["page", "sort", "q", "types", "min_distance", "from", "trip"])
            #expect(items.first { $0.name == "types" }?.value == "cycling,running")
            #expect(items.first { $0.name == "min_distance" }?.value == "5000.0")
            return .init(body: self.json(["tracks": [row], "types": ["walking": ["kind": "foot", "label": "Walk"]], "page": 2, "page_size": 100, "total": 150, "bounds": bounds]))
        }
        let query = TrackPageQuery(page: 2, sort: "distance_asc", q: "lake", types: ["cycling", "running"], minDistance: 5000, from: "2026-01-01", trip: "t1")
        let page = try await client().trackPage(query)
        #expect(page.tracks.map(\.id) == ["a1"])
        #expect(page.total == 150)
        #expect(page.pageSize == 100)
        #expect(page.distance == 800...42000)
        #expect(page.firstDate == "2024-03-01")
        #expect(page.typeCounts.map(\.type) == ["walking", "cycling"])
        #expect(page.types["walking"] == TrackTypeInfo(kind: .foot, label: "Walk"))
        StubProtocol.answer = { _ in .init(body: self.json(["tracks": [], "types": [:]])) }
        await #expect(throws: APIError.unreadable) { try await self.client().trackPage(query) }
    }

    @Test func aGPXDownloadIsSavedUnderTheServersName() async throws {
        StubProtocol.answer = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(request.url?.path == "/v2/tracks/gpx")
            #expect(items.first { $0.name == "ids" }?.value == "a1,a2")
            return .init(body: Data("PK".utf8), headers: ["Content-Disposition": "attachment; filename*=UTF-8''%D0%9F%D1%80%D0%BE%D0%B1%D0%B5%D0%B6%D0%BA%D0%B8.zip"])
        }
        let file = try await client().downloadTracksGPX(["a1", "a2"])
        #expect(file.lastPathComponent == "Пробежки.zip")
        #expect(try Data(contentsOf: file) == Data("PK".utf8))
        StubProtocol.answer = { _ in .init(body: Data("<gpx/>".utf8), headers: ["Content-Disposition": "attachment; filename=\"../../evil.gpx\""]) }
        #expect(try await client().downloadTracksGPX(["a1"]).lastPathComponent == "evil.gpx")
        StubProtocol.answer = { _ in .init(status: 409, body: self.json(["error": "gpx_pending", "message": "Morning walk is still being processed."])) }
        await #expect(throws: APIError.http(status: 409, code: "gpx_pending", message: "Morning walk is still being processed.")) {
            try await self.client().downloadTracksGPX(["a1"])
        }
    }

    @Test func importFailuresAreReadAndDismissedOneByOne() async throws {
        StubProtocol.answer = { request in
            #expect(request.url?.path == "/v2/uploads/active")
            return .init(body: self.json(["imports": [], "unseen_failures": 2, "failures": [
                ["id": 7, "title": "ride.fit", "reason": "Something went wrong on our side.", "finished_at": "2026-11-24T10:00:00Z"],
                ["id": 5, "title": "Walk, 3 Nov", "reason": "Try again later.", "finished_at": "2026-11-23T10:00:00Z"],
            ]]))
        }
        let failures = try await client().importFailures()
        #expect(failures == [ImportFailure(id: 7, title: "ride.fit", reason: "Something went wrong on our side."),
                             ImportFailure(id: 5, title: "Walk, 3 Nov", reason: "Try again later.")])
        #expect(ImportFailure.message(failures) == "ride.fit: Something went wrong on our side.\n\nWalk, 3 Nov: Try again later.")
        StubProtocol.answer = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/v2/uploads/seen")
            #expect(String(data: request.httpBody ?? Data(), encoding: .utf8) == #"{"id":7}"#)
            return .init(status: 204)
        }
        try await client().dismissImportFailure(7)
    }

    @Test func oneTrackIsReadInFull() async throws {
        let row: [String: Any] = ["id": "a1", "started_at": "2026-11-03T18:36:33Z", "timezone": "UTC", "track_type": "walking", "name": "Walk",
                                  "distance_meters": 1200.5, "moving_seconds": 600, "duration_seconds": 700, "description": "Along the river",
                                  "bbox": [-81.5, 41.2, -81.4, 41.3], "pending": false, "edited": false, "private": false, "split": NSNull(),
                                  "route_edit": NSNull(), "photos": NSNull(), "trips": []]
        StubProtocol.answer = { request in
            #expect(request.url?.path == "/v2/tracks/a1")
            return .init(body: self.json(["tracks": [row], "types": [:]]))
        }
        #expect(try await client().track("a1").description == "Along the river")
    }

    @Test func trackTypesAsksForTheNamedTypesAndReadsWhatTheServerSays() async throws {
        StubProtocol.answer = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(request.url?.path == "/v2/track-types")
            #expect(items.first { $0.name == "types" }?.value == "kayaking,e_bike")
            return .init(body: self.json(["used": [], "types": ["kayaking": ["kind": "other", "label": "Kayaking"]]]))
        }
        let types = try await client().trackTypes(["kayaking", "e_bike"])
        #expect(types == ["kayaking": TrackTypeInfo(kind: .other, label: "Kayaking")])
        StubProtocol.answer = { request in
            #expect(request.url?.query == nil)
            return .init(body: self.json(["used": [], "types": [:]]))
        }
        #expect(try await client().trackTypes([]).isEmpty)
    }

    @Test func typeCountsAreTheAccountsInTheServersOrder() async throws {
        StubProtocol.answer = { request in
            #expect(request.url?.path == "/v2/track-types")
            return .init(body: self.json(["used": [["type": "cycling", "count": 3], ["type": "kayaking", "count": 1]],
                                          "types": ["kayaking": ["kind": "other", "label": "Kayaking"]]]))
        }
        let read = try await client().typeCounts()
        #expect(read.counts.map(\.type) == ["cycling", "kayaking"])
        #expect(read.counts.map(\.count) == [3, 1])
        #expect(read.types["kayaking"] == TrackTypeInfo(kind: .other, label: "Kayaking"))
    }

    @Test func aTripsTracksComeWithTheirTypes() async throws {
        let row: [String: Any] = ["id": "a1", "started_at": "2026-11-03T18:36:33Z", "timezone": "UTC", "track_type": "walking", "name": NSNull(),
                                  "distance_meters": 1200.5, "moving_seconds": 600, "duration_seconds": 700, "description": NSNull(),
                                  "bbox": NSNull(), "pending": false, "edited": false, "private": false, "split": NSNull(), "trips": []]
        StubProtocol.answer = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(request.url?.path == "/v2/tracks")
            #expect(items.first { $0.name == "trip" }?.value == "t1")
            return .init(body: self.json(["tracks": [row], "types": ["walking": ["kind": "foot", "label": "Walk"]]]))
        }
        let read = try await client().tripTracks("t1")
        #expect(read.tracks.map(\.id) == ["a1"])
        #expect(read.types == ["walking": TrackTypeInfo(kind: .foot, label: "Walk")])
        StubProtocol.answer = { _ in .init(body: self.json(["tracks": [row]])) }
        await #expect(throws: (any Error).self) { try await self.client().tripTracks("t1") }
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
