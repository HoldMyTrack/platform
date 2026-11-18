import Foundation

/// The Tracks panel's calls: the list, its types, Pending, Edit, Delete, and Trips.
extension APIClient {
    /// `GET /v1/activities?story=`: that whole Trip's tracks (root docs/SPEC.md FR-13.6),
    /// newest first, with what the server says about their types.
    public func tripTracks(_ trip: String) async throws -> (tracks: [Track], types: [String: TrackTypeInfo]) {
        let json: ActivitiesJSON = try decode(try await send("GET", "v1/activities", query: [URLQueryItem(name: "story", value: trip)]))
        return (json.activities.map(Track.init), (json.types ?? [:]).mapValues(TrackTypeInfo.init))
    }

    /// `GET /v1/activities/area`: the newest tracks, at most limit, whose track crosses box
    /// (`[west, south, east, north]`), all of them without one, under dates; total is how many the
    /// box holds, more than listed when they were cut at the limit (root docs/SPEC.md FR-5.11).
    public func areaList(box: [Double]?, dates: DateFilter, limit: Int? = nil) async throws -> (tracks: [Track], total: Int?, types: [String: TrackTypeInfo]) {
        var items = dates.query
        if let box { items.append(URLQueryItem(name: "bbox", value: box.map { String($0) }.joined(separator: ","))) }
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        let json: AreaActivitiesJSON = try decode(try await send("GET", "v1/activities/area", query: items))
        return (json.activities.map(Track.init), json.total, json.types.mapValues(TrackTypeInfo.init))
    }

    /// `GET /v1/activities/{id}`: one track in full, for the Edit window.
    public func track(_ id: String) async throws -> Track {
        let json: ActivitiesJSON = try decode(try await send("GET", "v1/activities/\(id)"))
        guard let row = json.activities.first else { throw APIError.unreadable }
        return Track(row)
    }

    /// `GET /v1/activities/pending`: which of ids are still Pending, at most PendingDiff.batch.
    public func pending(_ ids: [String]) async throws -> [String] {
        let json: PendingJSON = try decode(try await send("GET", "v1/activities/pending", query: [URLQueryItem(name: "ids", value: ids.joined(separator: ","))]))
        return json.pending
    }

    /// `GET /v1/activities/{id}/track-metrics`: the track's points and their pace bands.
    public func trackMetrics(_ id: String) async throws -> RouteMetrics {
        RouteMetrics(try decode(try await send("GET", "v1/activities/\(id)/track-metrics")) as TrackMetricsJSON)
    }

    /// `GET /v1/activity-types`: the catalog, and types by name.
    public func activityTypes(_ types: [String]) async throws -> [String: TrackTypeInfo] {
        let query = types.isEmpty ? [] : [URLQueryItem(name: "types", value: types.joined(separator: ","))]
        let json: ActivityTypesJSON = try decode(try await send("GET", "v1/activity-types", query: query))
        return json.types.mapValues(TrackTypeInfo.init)
    }

    /// `PATCH /v1/activities/{id}`: a full replace of the three fields; an empty name or
    /// description clears it.
    public func updateTrack(_ write: EditPlan.Write) async throws -> Track {
        let body = ActivityPatchJSON(activityType: write.activityType, name: write.name, description: write.description)
        let json: ActivityRowJSON = try decode(try await send("PATCH", "v1/activities/\(write.id)", body: body))
        return Track(json)
    }

    /// `DELETE /v1/activities/{id}`: one already gone counts as deleted (DeleteOutcome).
    public func deleteTrack(_ id: String) async throws {
        try await delete("v1/activities/\(id)")
    }

    // MARK: Trips (root docs/SPEC.md FR-13)

    /// The Trip and the type labels its numbers carry.
    public typealias TripRead = (trip: Trip, types: [String: TrackTypeInfo])

    /// `GET /v1/stories`: every Trip, newest first.
    public func trips() async throws -> [TripRead] {
        let json: StoriesJSON = try decode(try await send("GET", "v1/stories"))
        return json.stories.map { (Trip($0), Trip.labels($0)) }
    }

    /// `GET /v1/stories/{id}`; a `404` is one that doesn't exist or isn't this account's.
    public func trip(_ id: String) async throws -> TripRead {
        try tripRead(try await send("GET", "v1/stories/\(id)"))
    }

    /// `POST /v1/stories`: a new Trip with trackIDs in it, in one step.
    public func createTrip(name: String, description: String, trackIDs: [String]) async throws -> TripRead {
        try tripRead(try await send("POST", "v1/stories", body: StoryCreateJSON(name: name, description: description, activityIDs: trackIDs)))
    }

    /// `PATCH /v1/stories/{id}`: both fields every time; an empty description clears it.
    public func updateTrip(_ id: String, name: String, description: String) async throws -> TripRead {
        try tripRead(try await send("PATCH", "v1/stories/\(id)", body: StoryInputJSON(name: name, description: description)))
    }

    /// `DELETE /v1/stories/{id}`: the Trip alone; its tracks stay.
    public func deleteTrip(_ id: String) async throws {
        try await delete("v1/stories/\(id)")
    }

    /// `POST` (add) or `DELETE /v1/stories/{id}/activities`: trackIDs into the Trip or out.
    public func changeTripTracks(_ id: String, trackIDs: [String], add: Bool) async throws -> TripRead {
        try tripRead(try await send(add ? "POST" : "DELETE", "v1/stories/\(id)/activities", body: StoryActivitiesJSON(activityIDs: trackIDs)))
    }

    /// `POST /v1/stories/{id}/send`: a copy to email, which succeeds whether or not the address
    /// has an account.
    public func sendTrip(_ id: String, email: String) async throws {
        _ = try await send("POST", "v1/stories/\(id)/send", body: EmailJSON(email: email))
    }

    /// `GET /v1/story-sends`: copies others sent, and accepted ones arriving.
    public func tripInbox() async throws -> TripInbox {
        let json: StoryInboxJSON = try decode(try await send("GET", "v1/story-sends"))
        return TripInbox(
            sends: json.sends.map { TripSend(id: $0.id, tripName: $0.storyName, from: $0.from, trackCount: $0.activityCount) },
            copying: json.copying.map { TripCopying(tripName: $0.storyName, from: $0.from) }
        )
    }

    /// `POST /v1/story-sends/{id}/accept`, or `DELETE /v1/story-sends/{id}` to decline.
    public func answerTripSend(_ id: String, accept: Bool) async throws {
        _ = try await send(accept ? "POST" : "DELETE", accept ? "v1/story-sends/\(id)/accept" : "v1/story-sends/\(id)")
    }

    private func tripRead(_ data: Data) throws -> TripRead {
        let json: StoryJSON = try decode(data)
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
}