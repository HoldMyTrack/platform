import Foundation

/// The Tracks panel's calls: the list, its types, Pending, Edit, Delete, and Trips.
extension APIClient {
    /// `GET /v2/tracks?trip=`: that whole Trip's tracks (root docs/SPEC.md FR-13.6),
    /// newest first, with what the server says about their types.
    public func tripTracks(_ trip: String) async throws -> (tracks: [Track], types: [String: TrackTypeInfo]) {
        let json: TracksJSON = try decode(try await send("GET", "v2/tracks", query: [URLQueryItem(name: "trip", value: trip)]))
        return (json.tracks.map(Track.init), json.types.mapValues(TrackTypeInfo.init))
    }

    /// `GET /v2/track-types` (root docs/SPEC.md FR-5.5): every type the account's tracks use with
    /// how many do, most first, whatever the map's area or filters, for both Type pickers, Edit's
    /// and a recording's, with what the server says about them.
    public func typeCounts() async throws -> (counts: [(type: String, count: Int)], types: [String: TrackTypeInfo]) {
        let json: TrackTypesJSON = try decode(try await send("GET", "v2/track-types"))
        return (json.used.map { (type: $0.type, count: $0.count) }, json.types.mapValues(TrackTypeInfo.init))
    }

    /// `GET /v2/tracks/area`: the newest tracks, at most limit, whose track crosses box
    /// (`[west, south, east, north]`), all of them without one, under dates; total is how many the
    /// box holds, more than listed when they were cut at the limit (root docs/SPEC.md FR-5.11).
    public func areaList(box: [Double]?, dates: DateFilter, limit: Int? = nil) async throws -> (tracks: [Track], total: Int?, types: [String: TrackTypeInfo]) {
        var items = dates.query
        if let box { items.append(URLQueryItem(name: "bbox", value: box.map { String($0) }.joined(separator: ","))) }
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        let json: AreaTracksJSON = try decode(try await send("GET", "v2/tracks/area", query: items))
        return (json.tracks.map(Track.init), json.total, json.types.mapValues(TrackTypeInfo.init))
    }

    /// `GET /v2/tracks/{id}`: one track in full, for the Edit window.
    public func track(_ id: String) async throws -> Track {
        let json: TracksJSON = try decode(try await send("GET", "v2/tracks/\(id)"))
        guard let row = json.tracks.first else { throw APIError.unreadable }
        return Track(row)
    }

    /// `GET /v2/tracks/pending`: which of ids are still Pending, at most PendingDiff.batch.
    public func pending(_ ids: [String]) async throws -> [String] {
        let json: PendingJSON = try decode(try await send("GET", "v2/tracks/pending", query: [URLQueryItem(name: "ids", value: ids.joined(separator: ","))]))
        return json.pending
    }

    /// `GET /v2/tracks/{id}/route-metrics`: the track's points and their pace bands.
    public func trackMetrics(_ id: String) async throws -> RouteMetrics {
        RouteMetrics(try decode(try await send("GET", "v2/tracks/\(id)/route-metrics")) as RouteMetricsJSON)
    }

    /// `GET /v2/track-types`: the catalog, and types by name.
    public func trackTypes(_ types: [String]) async throws -> [String: TrackTypeInfo] {
        let query = types.isEmpty ? [] : [URLQueryItem(name: "types", value: types.joined(separator: ","))]
        let json: TrackTypesJSON = try decode(try await send("GET", "v2/track-types", query: query))
        return json.types.mapValues(TrackTypeInfo.init)
    }

    /// `PATCH /v2/tracks/{id}`: a full replace of the three fields; an empty name or
    /// description clears it.
    public func updateTrack(_ write: EditPlan.Write) async throws -> Track {
        let body = TrackPatchJSON(trackType: write.trackType, name: write.name, description: write.description)
        let json: TrackRowJSON = try decode(try await send("PATCH", "v2/tracks/\(write.id)", body: body))
        return Track(json)
    }

    /// `DELETE /v2/tracks/{id}`: one already gone counts as deleted (DeleteOutcome).
    public func deleteTrack(_ id: String) async throws {
        try await delete("v2/tracks/\(id)")
    }

    // MARK: Trips (root docs/SPEC.md FR-13)

    /// The Trip and the type labels its numbers carry.
    public typealias TripRead = (trip: Trip, types: [String: TrackTypeInfo])

    /// `GET /v2/trips`: every Trip, newest first.
    public func trips() async throws -> [TripRead] {
        let json: TripsJSON = try decode(try await send("GET", "v2/trips"))
        return json.trips.map { (Trip($0), Trip.labels($0)) }
    }

    /// `GET /v2/trips/{id}`; a `404` is one that doesn't exist or isn't this account's.
    public func trip(_ id: String) async throws -> TripRead {
        try tripRead(try await send("GET", "v2/trips/\(id)"))
    }

    /// `POST /v2/trips`: a new Trip with trackIDs in it, in one step.
    public func createTrip(name: String, description: String, trackIDs: [String]) async throws -> TripRead {
        try tripRead(try await send("POST", "v2/trips", body: TripCreateJSON(name: name, description: description, trackIDs: trackIDs)))
    }

    /// `PATCH /v2/trips/{id}`: both fields every time; an empty description clears it.
    public func updateTrip(_ id: String, name: String, description: String) async throws -> TripRead {
        try tripRead(try await send("PATCH", "v2/trips/\(id)", body: TripInputJSON(name: name, description: description)))
    }

    /// `DELETE /v2/trips/{id}`: the Trip alone; its tracks stay.
    public func deleteTrip(_ id: String) async throws {
        try await delete("v2/trips/\(id)")
    }

    /// `POST` (add) or `DELETE /v2/trips/{id}/tracks`: trackIDs into the Trip or out.
    public func changeTripTracks(_ id: String, trackIDs: [String], add: Bool) async throws -> TripRead {
        try tripRead(try await send(add ? "POST" : "DELETE", "v2/trips/\(id)/tracks", body: TripTracksJSON(trackIDs: trackIDs)))
    }

    /// `POST /v2/trips/{id}/send`: a copy to email, which succeeds whether or not the address
    /// has an account.
    public func sendTrip(_ id: String, email: String) async throws {
        _ = try await send("POST", "v2/trips/\(id)/send", body: EmailJSON(email: email))
    }

    /// `GET /v2/trip-sends`: copies others sent, and accepted ones arriving.
    public func tripInbox() async throws -> TripInbox {
        let json: TripInboxJSON = try decode(try await send("GET", "v2/trip-sends"))
        return TripInbox(
            sends: json.sends.map { TripSend(id: $0.id, tripName: $0.tripName, from: $0.from, trackCount: $0.trackCount) },
            copying: json.copying.map { TripCopying(tripName: $0.tripName, from: $0.from) }
        )
    }

    /// `POST /v2/trip-sends/{id}/accept`, or `DELETE /v2/trip-sends/{id}` to decline.
    public func answerTripSend(_ id: String, accept: Bool) async throws {
        _ = try await send(accept ? "POST" : "DELETE", accept ? "v2/trip-sends/\(id)/accept" : "v2/trip-sends/\(id)")
    }

    private func tripRead(_ data: Data) throws -> TripRead {
        let json: TripJSON = try decode(data)
        return (Trip(json), Trip.labels(json))
    }

    /// A DELETE whose answer DeleteOutcome reads: one already gone is done too.
    func delete(_ path: String) async throws {
        do {
            _ = try await send("DELETE", path)
        } catch APIError.http(let status, let code, let message) {
            if !DeleteOutcome.done(status: status) { throw APIError.http(status: status, code: code, message: message) }
        }
    }

    /// `POST /v2/tracks/info` (root docs/SPEC.md FR-5.8): the toolbar's Info for trackIDs, its
    /// lines formatted by the server.
    public func trackInfo(_ trackIDs: [String]) async throws -> TrackInfo {
        let json: TrackInfoJSON = try decode(try await send("POST", "v2/tracks/info", body: TrackInfoRequestJSON(trackIDs: trackIDs)))
        return TrackInfo(lines: json.lines.map { TrackInfo.Line(label: $0.label, value: $0.value) }, note: json.note)
    }

    /// `POST /v2/tracks/stats-card` (root docs/IMPLEMENTATION.md §4.3.3): the export's stats card
    /// for request as a PNG drawn at the image's own scale, or nil when every track is Pending (204).
    public func statsCard(_ request: ExportStats.Request) async throws -> Data? {
        let body = StatsCardRequestJSON(trackIDs: request.trackIDs, width: request.width, height: request.height, theme: request.dark ? "dark" : "light")
        let data = try await send("POST", "v2/tracks/stats-card", body: body)
        return data.isEmpty ? nil : data
    }

    /// The account's track each span overlaps the most (`POST /v2/tracks/overlaps`), by key: the
    /// server's half of the Sync tab's similar-tracks hint (docs/SPEC.md FR-3.5).
    public func trackOverlaps(_ tracks: [RecordedTrack]) async throws -> [String: TrackOverlap] {
        guard !tracks.isEmpty else { return [:] }
        let time = ISO8601DateFormatter()
        time.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body = OverlapsRequestJSON(spans: tracks.map { OverlapSpanJSON(key: $0.id, start: time.string(from: $0.startedAt), end: time.string(from: $0.endedAt)) })
        let json: OverlapsJSON = try decode(try await send("POST", "v2/tracks/overlaps", body: body))
        return Dictionary(json.overlaps.map { ($0.key, TrackOverlap($0)) }, uniquingKeysWith: { a, _ in a })
    }
}
