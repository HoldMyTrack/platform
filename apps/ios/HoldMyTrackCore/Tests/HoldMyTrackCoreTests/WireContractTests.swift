import Foundation
import Testing

@testable import HoldMyTrackCore

/// Holds every type in Wire.swift to the API contract, services/server/api: each response type to
/// the response it decodes, each request type to the body it sends. A field the server renames,
/// drops or makes nullable fails here, in CI, rather than in a decode on a phone.
struct WireContractTests {
    @Test func everyWireTypeMatchesTheContract() throws {
        let contract = Contract()
        let check = WireCheck()
        func response<T: Decodable>(_ type: T.Type, _ path: String, _ method: String, _ status: Int = 200) throws {
            check.check(T.self, try contract.response(path, method, status), at: "\(method) \(path) \(status)", .response)
        }
        func request<T: Decodable>(_ type: T.Type, _ path: String, _ method: String) throws {
            check.check(T.self, try contract.request(path, method), at: "\(method) \(path) request", .request)
        }

        try response(ErrorJSON.self, "/trips/{id}", "get", 404)
        try response(AccountJSON.self, "/auth/me", "get")
        for path in ["/auth/login", "/auth/handoff", "/auth/apple/token"] {
            try response(AccountJSON.self, path, "post")
            try response(SessionTokenJSON.self, path, "post")
        }
        try response(SessionTokenJSON.self, "/auth/demo", "post", 201)
        try response(AccountJSON.self, "/account/settings", "patch")
        try response(MessageJSON.self, "/auth/resend-verification", "post")
        try response(AccountJSON.self, "/auth/verify-code", "post")
        try response(ProvidersJSON.self, "/auth/providers", "get")
        try response(SettingsOptionsJSON.self, "/account/settings/options", "get")
        try response(ExportStatusJSON.self, "/account/export", "get")
        try response(ExportStatusJSON.self, "/account/export", "post", 202)
        try request(CredentialsJSON.self, "/auth/login", "post")
        try request(AppleTokenJSON.self, "/auth/apple/token", "post")
        try request(HandoffJSON.self, "/auth/handoff", "post")
        try request(CodeJSON.self, "/auth/verify-code", "post")
        try request(SettingsJSON.self, "/account/settings", "patch")
        try request(EmailJSON.self, "/account", "delete")
        try request(EmailJSON.self, "/trips/{id}/send", "post")

        try response(TracksJSON.self, "/tracks", "get")
        try response(AreaTracksJSON.self, "/tracks/area", "get")
        try response(TracksJSON.self, "/tracks/{id}", "get")
        try response(TrackTypesJSON.self, "/track-types", "get")
        try response(PendingJSON.self, "/tracks/pending", "get")
        try response(TrackRowJSON.self, "/tracks/{id}", "patch")
        try request(TrackPatchJSON.self, "/tracks/{id}", "patch")
        try response(HistogramJSON.self, "/tracks/histogram", "get")
        try response(CoverageStatusJSON.self, "/coverage/status", "get")
        try response(RouteMetricsJSON.self, "/tracks/{id}/route-metrics", "get")
        try response(RoutePointsJSON.self, "/tracks/{id}/route-points", "get")
        try request(RouteEditRequestJSON.self, "/tracks/{id}/route-edit", "post")
        try request(OverlapsRequestJSON.self, "/tracks/overlaps", "post")
        try request(StatsCardRequestJSON.self, "/tracks/stats-card", "post")
        try response(OverlapsJSON.self, "/tracks/overlaps", "post")
        try response(UploadResultJSON.self, "/tracks/upload", "post", 202)
        try response(UploadResultJSON.self, "/tracks/upload", "post", 200)
        try response(UploadsActiveJSON.self, "/uploads/active", "get")

        try request(SyncTracksRequestJSON.self, "/sync/tracks", "post")
        try response(SyncResultsJSON.self, "/sync/tracks", "post")
        try request(SyncKnownRequestJSON.self, "/sync/known", "post")
        try response(SyncKnownJSON.self, "/sync/known", "post")

        try response([PrivateLocationJSON].self, "/private-locations", "get")
        try response(HiddenTracksJSON.self, "/private-locations/hidden", "get")
        try response(PrivateLocationJSON.self, "/private-locations", "post", 201)
        try response(PrivateLocationJSON.self, "/private-locations/{id}", "patch")
        try request(PrivateLocationInputJSON.self, "/private-locations", "post")
        try request(PrivateLocationInputJSON.self, "/private-locations/{id}", "patch")

        try response(TripsJSON.self, "/trips", "get")
        try response(TripJSON.self, "/trips", "post", 201)
        try response(TripJSON.self, "/trips/{id}", "get")
        try response(TripJSON.self, "/trips/{id}", "patch")
        try response(TripJSON.self, "/trips/{id}/tracks", "post")
        try response(TripJSON.self, "/trips/{id}/tracks", "delete")
        try request(TripCreateJSON.self, "/trips", "post")
        try request(TripInputJSON.self, "/trips/{id}", "patch")
        try request(TripTracksJSON.self, "/trips/{id}/tracks", "post")
        try request(TripTracksJSON.self, "/trips/{id}/tracks", "delete")
        try response(TripInboxJSON.self, "/trip-sends", "get")

        try response(PhotosJSON.self, "/photos", "get")
        try response(PhotoJSON.self, "/photos", "post", 201)
        try response(PhotoJSON.self, "/photos/{id}", "patch")
        try request(PhotoPlaceRequestJSON.self, "/photos/place", "post")
        try response(PhotoPlaceJSON.self, "/photos/place", "post")
        try request(PhotoPatchJSON.self, "/photos/{id}", "patch")

        try response(SpotsInAreaJSON.self, "/spots", "get")
        try response(SpotDetailJSON.self, "/spots/{id}", "get")
        try response(SpotCapturesJSON.self, "/spots/captures", "get")
        try response(SpotCaptureJSON.self, "/spots/{id}/captures", "post", 201)
        try response(SpotCaptureJSON.self, "/spots/{id}/captures", "post", 200)
        try request(SpotCaptureRequestJSON.self, "/spots/{id}/captures", "post")

        #expect(check.problems.joined(separator: "\n") == "")

        // Every type in Wire.swift is reached by some check above, so a new one can't go unchecked.
        let source = try String(contentsOf: contract.root.appending(path: "apps/ios/HoldMyTrackCore/Sources/HoldMyTrackCore/Wire.swift"), encoding: .utf8)
        let declared = Set(source.matches(of: /struct (\w+JSON):/).map { String($0.output.1) })
        #expect(declared.subtracting(check.seen).sorted() == [], "Wire.swift types no check reaches")
    }

    // The checker's own rules, against schemas written here.

    private struct NonNull: Decodable { let a: String }
    private struct Nullable: Decodable { let a: String? }
    private struct Number: Decodable { let a: Int }
    private struct Map: Decodable { let a: [String: Number] }

    private func problems<T: Decodable>(_ type: T.Type, _ schema: Schema, _ mode: WireMode = .response) -> [String] {
        let check = WireCheck()
        check.check(T.self, schema, at: "test", mode)
        return check.problems
    }

    private func object(_ required: [String], _ properties: [String: Schema]) -> Schema {
        ["type": "object", "required": required, "properties": properties]
    }

    @Test func aFieldTheContractMakesNullableMustBeOptional() {
        let schema = object(["a"], ["a": ["type": "string", "nullable": true]])
        #expect(problems(NonNull.self, schema).first?.contains("can be null") == true)
        #expect(problems(Nullable.self, schema) == [])
    }

    @Test func aFieldTheContractDoesntRequireMustBeOptional() {
        let schema = object([], ["a": ["type": "string"]])
        #expect(problems(NonNull.self, schema).first?.contains("require") == true)
        #expect(problems(Nullable.self, schema) == [])
    }

    @Test func aFieldMissingFromTheContractOrOfAnotherTypeIsAProblem() {
        #expect(problems(NonNull.self, object(["b"], ["b": ["type": "string"]])).first?.contains("not in the contract") == true)
        #expect(problems(Number.self, object(["a"], ["a": ["type": "string"]])).first?.contains("integer") == true)
    }

    @Test func aRequestMustSendWhatTheContractRequires() {
        let schema = object(["a", "b"], ["a": ["type": "string"], "b": ["type": "string"]])
        let found = problems(Nullable.self, schema, .request)
        #expect(found.contains { $0.contains("can't be left out") })
        #expect(found.contains { $0.contains("requires b") })
        #expect(problems(NonNull.self, object(["a"], ["a": ["type": "string"]]), .request) == [])
    }

    @Test func aMapIsCheckedAgainstAdditionalProperties() {
        let values: Schema = object(["a"], ["a": ["type": "integer"]])
        #expect(problems(Map.self, object(["a"], ["a": ["type": "object", "additionalProperties": values]])) == [])
        #expect(problems(Map.self, object(["a"], ["a": ["type": "object", "additionalProperties": false]])).first?.contains("map") == true)
    }
}
