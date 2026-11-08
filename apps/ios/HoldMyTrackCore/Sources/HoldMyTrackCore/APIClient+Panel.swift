import Foundation

/// The Activities panel's calls: the list, its types, Pending, Edit, Delete, and Stories.
extension APIClient {
    /// `GET /v1/activities`: the range's activities (from and to, the account's days), or with
    /// story that whole Story's whatever the range (root docs/SPEC.md FR-14.6), newest first, with
    /// what the server says about their types.
    public func activityList(from: String?, to: String?, story: String?) async throws -> (activities: [Activity], types: [String: ActivityTypeInfo]) {
        var items: [URLQueryItem] = []
        if let story {
            items.append(URLQueryItem(name: "story", value: story))
        } else if let from, let to {
            items += [URLQueryItem(name: "from", value: from), URLQueryItem(name: "to", value: to)]
        }
        let json: ActivitiesJSON = try decode(try await send("GET", "v1/activities", query: items))
        return (json.activities.map(Activity.init), (json.types ?? [:]).mapValues(ActivityTypeInfo.init))
    }

    /// `GET /v1/activities/pending`: which of ids are still Pending, at most PendingDiff.batch.
    public func pending(_ ids: [String]) async throws -> [String] {
        let json: PendingJSON = try decode(try await send("GET", "v1/activities/pending", query: [URLQueryItem(name: "ids", value: ids.joined(separator: ","))]))
        return json.pending
    }

    /// `GET /v1/activity-types`: the catalog, and types by name.
    public func activityTypes(_ types: [String]) async throws -> [String: ActivityTypeInfo] {
        let query = types.isEmpty ? [] : [URLQueryItem(name: "types", value: types.joined(separator: ","))]
        let json: ActivityTypesJSON = try decode(try await send("GET", "v1/activity-types", query: query))
        return json.types.mapValues(ActivityTypeInfo.init)
    }

    /// `PATCH /v1/activities/{id}`: a full replace of the three fields; an empty name or
    /// description clears it.
    public func updateActivity(_ write: EditPlan.Write) async throws -> Activity {
        let body = ActivityPatchJSON(activityType: write.activityType, name: write.name, description: write.description)
        let json: ActivityRowJSON = try decode(try await send("PATCH", "v1/activities/\(write.id)", body: body))
        return Activity(json)
    }

    /// `DELETE /v1/activities/{id}`: one already gone counts as deleted (DeleteOutcome).
    public func deleteActivity(_ id: String) async throws {
        try await delete("v1/activities/\(id)")
    }

    // MARK: Stories (root docs/SPEC.md FR-14)

    /// The Story and the type labels its numbers carry.
    public typealias StoryRead = (story: Story, types: [String: ActivityTypeInfo])

    /// `GET /v1/stories`: every Story, newest first.
    public func stories() async throws -> [StoryRead] {
        let json: StoriesJSON = try decode(try await send("GET", "v1/stories"))
        return json.stories.map { (Story($0), Story.labels($0)) }
    }

    /// `GET /v1/stories/{id}`; a `404` is one that doesn't exist or isn't this account's.
    public func story(_ id: String) async throws -> StoryRead {
        try storyRead(try await send("GET", "v1/stories/\(id)"))
    }

    /// `POST /v1/stories`: a new Story with activityIDs in it, in one step.
    public func createStory(name: String, description: String, activityIDs: [String]) async throws -> StoryRead {
        try storyRead(try await send("POST", "v1/stories", body: StoryCreateJSON(name: name, description: description, activityIDs: activityIDs)))
    }

    /// `PATCH /v1/stories/{id}`: both fields every time; an empty description clears it.
    public func updateStory(_ id: String, name: String, description: String) async throws -> StoryRead {
        try storyRead(try await send("PATCH", "v1/stories/\(id)", body: StoryInputJSON(name: name, description: description)))
    }

    /// `DELETE /v1/stories/{id}`: the Story alone; its activities stay.
    public func deleteStory(_ id: String) async throws {
        try await delete("v1/stories/\(id)")
    }

    /// `POST` (add) or `DELETE /v1/stories/{id}/activities`: activityIDs into the Story or out.
    public func changeStoryActivities(_ id: String, activityIDs: [String], add: Bool) async throws -> StoryRead {
        try storyRead(try await send(add ? "POST" : "DELETE", "v1/stories/\(id)/activities", body: StoryActivitiesJSON(activityIDs: activityIDs)))
    }

    /// `POST /v1/stories/{id}/send`: a copy to email, which succeeds whether or not the address
    /// has an account.
    public func sendStory(_ id: String, email: String) async throws {
        _ = try await send("POST", "v1/stories/\(id)/send", body: EmailJSON(email: email))
    }

    /// `GET /v1/story-sends`: copies others sent, and accepted ones arriving.
    public func storyInbox() async throws -> StoryInbox {
        let json: StoryInboxJSON = try decode(try await send("GET", "v1/story-sends"))
        return StoryInbox(
            sends: json.sends.map { StorySend(id: $0.id, storyName: $0.storyName, from: $0.from, activityCount: $0.activityCount) },
            copying: json.copying.map { StoryCopying(storyName: $0.storyName, from: $0.from) }
        )
    }

    /// `POST /v1/story-sends/{id}/accept`, or `DELETE /v1/story-sends/{id}` to decline.
    public func answerStorySend(_ id: String, accept: Bool) async throws {
        _ = try await send(accept ? "POST" : "DELETE", accept ? "v1/story-sends/\(id)/accept" : "v1/story-sends/\(id)")
    }

    private func storyRead(_ data: Data) throws -> StoryRead {
        let json: StoryJSON = try decode(data)
        return (Story(json), Story.labels(json))
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