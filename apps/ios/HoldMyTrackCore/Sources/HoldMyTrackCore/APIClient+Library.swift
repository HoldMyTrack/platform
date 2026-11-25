import Foundation

/// `GET /v2/tracks`'s query for one page of Library: sort is `key_desc` or `key_asc`, and a nil
/// field asks for no filter (LibraryRules.pageQuery).
public struct TrackPageQuery: Equatable, Sendable {
    public var page: Int
    public var sort: String
    public var q: String?
    public var types: [String]?
    public var minDistance: Double?
    public var maxDistance: Double?
    public var from: String?
    public var to: String?
    public var trip: String?

    public init(
        page: Int, sort: String, q: String? = nil, types: [String]? = nil, minDistance: Double? = nil,
        maxDistance: Double? = nil, from: String? = nil, to: String? = nil, trip: String? = nil
    ) {
        self.page = page
        self.sort = sort
        self.q = q
        self.types = types
        self.minDistance = minDistance
        self.maxDistance = maxDistance
        self.from = from
        self.to = to
        self.trip = trip
    }

    var items: [URLQueryItem] {
        var items = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "sort", value: sort)]
        func add(_ name: String, _ value: String?) {
            if let value { items.append(URLQueryItem(name: name, value: value)) }
        }
        add("q", q)
        add("types", types?.joined(separator: ","))
        add("min_distance", minDistance.map { String($0) })
        add("max_distance", maxDistance.map { String($0) })
        add("from", from)
        add("to", to)
        add("trip", trip)
        return items
    }
}

/// One page of Library: its rows, how many tracks pass the filters, the page size, and the
/// filters' bounds over every track of the account.
public struct TrackPage: Equatable, Sendable {
    public let tracks: [Track]
    public let total: Int
    public let pageSize: Int
    /// The shortest and longest track with a route; nil when none has one.
    public let distance: ClosedRange<Double>?
    public let firstDate: String?
    public let lastDate: String?
    /// Each type the account's tracks use, with how many do, most first.
    public let typeCounts: [TypeCount]
    /// What the server says about every type in the rows and the bounds.
    public let types: [String: TrackTypeInfo]

    public struct TypeCount: Equatable, Sendable {
        public let type: String
        public let count: Int
    }
}

/// Library's calls (root docs/SPEC.md FR-17): a page of the whole collection, and Download.
extension APIClient {
    /// `GET /v2/tracks?page=`: one page of Library, as query asks for it.
    public func trackPage(_ query: TrackPageQuery) async throws -> TrackPage {
        let json: TrackPageJSON = try decode(try await send("GET", "v2/tracks", query: query.items))
        guard let bounds = json.bounds else { throw APIError.unreadable }
        let distance: ClosedRange<Double>? = if let lo = bounds.minDistanceMeters, let hi = bounds.maxDistanceMeters, lo <= hi { lo...hi } else { nil }
        return TrackPage(
            tracks: json.tracks.map(Track.init),
            total: json.total ?? 0,
            pageSize: json.pageSize.flatMap { $0 > 0 ? $0 : nil } ?? DownloadRules.maxTracks,
            distance: distance,
            firstDate: bounds.firstDate,
            lastDate: bounds.lastDate,
            typeCounts: bounds.types.map { TrackPage.TypeCount(type: $0.type, count: $0.count) },
            types: json.types.mapValues(TrackTypeInfo.init)
        )
    }

    /// `GET /v2/tracks/gpx?ids=` (root docs/SPEC.md FR-17.2): one track as GPX, or several as a
    /// zip, saved to a temporary file named as the server names it (AttachmentName). The long
    /// timeout is for a page of tracks, zipped before the first byte comes back. The caller removes
    /// the file's directory once it is shared or saved.
    public func downloadTracksGPX(_ ids: [String]) async throws -> URL {
        var request = request("GET", "v2/tracks/gpx")
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "ids", value: ids.joined(separator: ","))]
        request.url = components.url
        request.setValue("application/gpx+xml, application/zip, application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 600
        let (data, http) = try await performWithResponse(request)
        let name = (AttachmentName.of(http.value(forHTTPHeaderField: "Content-Disposition")) as NSString).lastPathComponent
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let unsafe = name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains("\0")
        let file = dir.appending(path: unsafe ? AttachmentName.fallback : name)
        try data.write(to: file)
        return file
    }
}
