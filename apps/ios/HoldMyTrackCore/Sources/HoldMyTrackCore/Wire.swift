import Foundation

// The API's request and response bodies as they travel, one type each, named after the JSON
// they read or write, with the server's snake_case in CodingKeys. Every type here is checked
// against the API contract, services/server/api (WireContractTests): a field the server renames,
// drops or starts sending as null fails that test rather than a decode on someone's phone.
// Hand-written, as the Android app's net/Wire.kt is, and with the same fields, so a type here
// and its Kotlin counterpart read the same JSON.
//
// A response type lists only the fields the app reads. Rules the test holds them to:
// - A field that isn't optional must be one the contract requires and never null.
// - A field the contract makes nullable, or doesn't require, is optional.
// - Its JSON type is the contract's: a String a string, Int an integer, Double a number.
//
// Unknown keys are skipped, so a field the server adds breaks no version of the app, and a nil
// is left out of a request rather than sent: both are JSONDecoder's and JSONEncoder's defaults.

// Errors (docs/SPEC.md §1.4)

struct ErrorJSON: Codable, Sendable, Equatable {
    let error: String?
    let message: String?
}

// Accounts and sessions

struct AccountJSON: Codable, Sendable, Equatable {
    let email: String
    let isDemo: Bool
    let emailVerified: Bool
    let displayName: String
    let country: String
    let timezone: String
    let locale: String
    let avatarURL: String
    /// "imperial" or "metric", decided by the server from country (ADR-0048).
    let unitSystem: String

    enum CodingKeys: String, CodingKey {
        case email, isDemo, country, timezone, locale
        case emailVerified = "email_verified"
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case unitSystem = "unit_system"
    }
}

/// The token half of a session response; the account half is AccountJSON, read from the same
/// body.
struct SessionTokenJSON: Codable, Sendable, Equatable {
    let sessionToken: String

    enum CodingKeys: String, CodingKey {
        case sessionToken = "session_token"
    }
}

struct MessageJSON: Codable, Sendable, Equatable {
    let message: String
}

struct ProvidersJSON: Codable, Sendable, Equatable {
    let google: Bool
    let facebook: Bool
    let apple: Bool
}

struct SettingsOptionJSON: Codable, Sendable, Equatable {
    let value: String
    let label: String
}

struct TimezoneGroupJSON: Codable, Sendable, Equatable {
    let region: String
    let label: String
    let options: [SettingsOptionJSON]
}

struct SettingsOptionsJSON: Codable, Sendable, Equatable {
    let countries: [SettingsOptionJSON]
    let timezones: [TimezoneGroupJSON]
    let languages: [SettingsOptionJSON]
}

struct ExportPartJSON: Codable, Sendable, Equatable {
    let n: Int
    let size: Int
    let name: String
    let url: String
}

struct ExportStatusJSON: Codable, Sendable, Equatable {
    let state: String
    let expiresAt: String?
    let totalSize: Int?
    let parts: [ExportPartJSON]?

    enum CodingKeys: String, CodingKey {
        case state, parts
        case expiresAt = "expires_at"
        case totalSize = "total_size"
    }
}

struct CredentialsJSON: Codable, Sendable, Equatable {
    let email: String
    let password: String
}

/// Sign in with Apple's authorization code; name is only on the first authorization.
struct AppleTokenJSON: Codable, Sendable, Equatable {
    let authorizationCode: String
    let name: String?
    let tz: String?

    enum CodingKeys: String, CodingKey {
        case name, tz
        case authorizationCode = "authorization_code"
    }
}

struct HandoffJSON: Codable, Sendable, Equatable {
    let code: String
    let verifier: String
}

struct SettingsJSON: Codable, Sendable, Equatable {
    let displayName: String
    let country: String
    let timezone: String
    let locale: String

    enum CodingKeys: String, CodingKey {
        case country, timezone, locale
        case displayName = "display_name"
    }
}

struct EmailJSON: Codable, Sendable, Equatable {
    let email: String
}

struct CodeJSON: Codable, Sendable, Equatable {
    let code: String
}

// Tracks

struct TripRefJSON: Codable, Sendable, Equatable {
    let id: String
    let name: String
}

struct TrackRowJSON: Codable, Sendable, Equatable {
    let id: String
    let startedAt: String
    let timezone: String
    let trackType: String
    let name: String?
    let distanceMeters: Double?
    let movingSeconds: Int?
    let description: String?
    let bbox: [Double]?
    let pending: Bool
    let edited: Bool
    let `private`: Bool
    let routeEdit: String?
    let photos: String?
    let trips: [TripRefJSON]

    enum CodingKeys: String, CodingKey {
        case id, timezone, name, description, bbox, pending, edited, `private`, photos, trips
        case startedAt = "started_at"
        case trackType = "track_type"
        case distanceMeters = "distance_meters"
        case movingSeconds = "moving_seconds"
        case routeEdit = "route_edit"
    }
}

struct TracksJSON: Codable, Sendable, Equatable {
    let tracks: [TrackRowJSON]
    let types: [String: TrackTypeJSON]
}

/// `GET /v2/tracks` with `page`: one page of Library (root docs/SPEC.md FR-17.1).
struct TrackPageJSON: Codable, Sendable, Equatable {
    let tracks: [TrackRowJSON]
    let types: [String: TrackTypeJSON]
    let pageSize: Int?
    let total: Int?
    let bounds: TrackPageBoundsJSON?

    enum CodingKeys: String, CodingKey {
        case tracks, types, total, bounds
        case pageSize = "page_size"
    }
}

/// The filters' bounds over every track of the account; nil where no track sets one.
struct TrackPageBoundsJSON: Codable, Sendable, Equatable {
    let minDistanceMeters: Double?
    let maxDistanceMeters: Double?
    let firstDate: String?
    let lastDate: String?
    let types: [TypeCountJSON]

    enum CodingKeys: String, CodingKey {
        case types
        case minDistanceMeters = "min_distance_meters"
        case maxDistanceMeters = "max_distance_meters"
        case firstDate = "first_date"
        case lastDate = "last_date"
    }
}

/// A track as the area list's row shows it; `GET /v2/tracks/{id}` has the rest.
struct AreaTrackRowJSON: Codable, Sendable, Equatable {
    let id: String
    let startedAt: String
    let timezone: String
    let trackType: String
    let name: String?
    let distanceMeters: Double?
    let movingSeconds: Int?
    let bbox: [Double]?
    let pending: Bool
    let `private`: Bool
    let trips: [TripRefJSON]

    enum CodingKeys: String, CodingKey {
        case id, timezone, name, bbox, pending, `private`, trips
        case startedAt = "started_at"
        case trackType = "track_type"
        case distanceMeters = "distance_meters"
        case movingSeconds = "moving_seconds"
    }
}

/// `GET /v2/tracks/area`.
struct AreaTracksJSON: Codable, Sendable, Equatable {
    let tracks: [AreaTrackRowJSON]
    let types: [String: TrackTypeJSON]
    let total: Int?
}

/// `GET /v2/tracks/pending`.
struct PendingJSON: Codable, Sendable, Equatable {
    let pending: [String]
}

/// What a client shows for one track type.
struct TrackTypeJSON: Codable, Sendable, Equatable {
    let kind: String
    let label: String
}

struct TrackTypesJSON: Codable, Sendable, Equatable {
    let used: [TypeCountJSON]
    let types: [String: TrackTypeJSON]
}

/// A type the account's tracks use, and how many do.
struct TypeCountJSON: Codable, Sendable, Equatable {
    let type: String
    let count: Int
}

struct TrackPatchJSON: Codable, Sendable, Equatable {
    let trackType: String
    let name: String
    let description: String

    enum CodingKeys: String, CodingKey {
        case name, description
        case trackType = "track_type"
    }
}

struct HistogramBucketJSON: Codable, Sendable, Equatable {
    let date: String
    let count: Int
    let distanceMeters: Double

    enum CodingKeys: String, CodingKey {
        case date, count
        case distanceMeters = "distance_meters"
    }
}

struct HistogramJSON: Codable, Sendable, Equatable {
    let buckets: [HistogramBucketJSON]
    let earliest: String?
}

struct ExploredJSON: Codable, Sendable, Equatable {
    let countries: Int
    let regions: Int
    let counties: Int
    let cities: Int
}

struct CoverageStatusJSON: Codable, Sendable, Equatable {
    let rendering: Bool
    let version: Int
    let tileVersion: String
    let explored: ExploredJSON?

    enum CodingKeys: String, CodingKey {
        case rendering, version, explored
        case tileVersion = "tile_version"
    }
}

struct RouteMetricPointJSON: Codable, Sendable, Equatable {
    let lon: Double
    let lat: Double
    let speedMps: Double
    let timeS: Int

    enum CodingKeys: String, CodingKey {
        case lon, lat
        case speedMps = "speed_mps"
        case timeS = "time_s"
    }
}

struct PaceBandJSON: Codable, Sendable, Equatable {
    let band: Int
    let start: Int
    let end: Int
}

struct RouteMetricsJSON: Codable, Sendable, Equatable {
    let trackID: String
    let points: [RouteMetricPointJSON]
    let bands: [PaceBandJSON]

    enum CodingKeys: String, CodingKey {
        case points, bands
        case trackID = "track_id"
    }
}

/// A route edit both ways: what the editor opens with and what Apply sends. Times are Unix ms; a
/// pair is a two-element array, and move is keyed by a time, which JSON carries as a string.
struct RouteEditJSON: Codable, Sendable, Equatable {
    let keep: [Int]?
    let remove: [[Int]]?
    let drop: [Int]?
    let move: [String: [Double]]?
}

/// points are `[lon, lat, t]`, t in Unix ms.
struct RoutePointsJSON: Codable, Sendable, Equatable {
    let points: [[Double]]
    let edit: RouteEditJSON?
}

struct RouteEditRequestJSON: Codable, Sendable, Equatable {
    let edit: RouteEditJSON?
    let splitAt: Int?
    let allowHidden: Bool?

    enum CodingKeys: String, CodingKey {
        case edit
        case splitAt = "split_at"
        case allowHidden = "allow_hidden"
    }
}

struct OverlapSpanJSON: Codable, Sendable, Equatable {
    let key: String
    let start: String
    let end: String
}

struct StatsCardRequestJSON: Codable, Sendable, Equatable {
    let trackIDs: [String]
    let width: Int
    let height: Int
    let theme: String

    enum CodingKeys: String, CodingKey {
        case trackIDs = "track_ids"
        case width, height, theme
    }
}

struct TrackInfoRequestJSON: Codable, Sendable, Equatable {
    let trackIDs: [String]

    enum CodingKeys: String, CodingKey {
        case trackIDs = "track_ids"
    }
}

struct TrackInfoJSON: Codable, Sendable, Equatable {
    struct Line: Codable, Sendable, Equatable {
        let label: String
        let value: String
    }

    let lines: [Line]
    let note: String
}

struct HiddenTracksJSON: Codable, Sendable, Equatable {
    let count: Int
}

struct OverlapsRequestJSON: Codable, Sendable, Equatable {
    let spans: [OverlapSpanJSON]
}

struct OverlapJSON: Codable, Sendable, Equatable {
    let key: String
    let trackID: String
    let name: String
    let trackType: String
    let startedAt: String
    let timezone: String?

    enum CodingKeys: String, CodingKey {
        case key, name, timezone
        case trackID = "track_id"
        case trackType = "track_type"
        case startedAt = "started_at"
    }
}

struct OverlapsJSON: Codable, Sendable, Equatable {
    let overlaps: [OverlapJSON]
}

struct UploadResultJSON: Codable, Sendable, Equatable {
    let status: String
    /// Optional, as on Android: an answer without it still says whether the file went.
    let externalID: String?
    let filename: String?

    enum CodingKeys: String, CodingKey {
        case status, filename
        case externalID = "external_id"
    }
}

/// `GET /v2/uploads/{external_id}`: an uploaded file's state.
struct UploadStatusJSON: Codable, Sendable, Equatable {
    let status: String
    let error: String?
}

/// One batch of imports still running, `GET /v2/uploads/active`.
struct ActiveImportJSON: Codable, Sendable, Equatable {
    let title: String
    let source: String
    let done: Int
    let total: Int
}

struct UploadsActiveJSON: Codable, Sendable, Equatable {
    let imports: [ActiveImportJSON]
    let unseenFailures: Int
    let failures: [ImportFailureJSON]

    enum CodingKeys: String, CodingKey {
        case imports, failures
        case unseenFailures = "unseen_failures"
    }
}

/// An import that failed on the server's side and the account hasn't seen.
struct ImportFailureJSON: Codable, Sendable, Equatable {
    let id: Int
    let title: String
    let reason: String
    let finishedAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, reason
        case finishedAt = "finished_at"
    }
}

/// `POST /v2/uploads/seen`.
struct UploadSeenJSON: Codable, Sendable, Equatable {
    let id: Int
}

// Sync

/// One point of a synced track. elevationM is left out when unknown: no altitude is not sea
/// level.
struct SyncPointJSON: Codable, Sendable, Equatable {
    let lat: Double
    let lon: Double
    let elevationM: Double?
    let time: String

    enum CodingKeys: String, CodingKey {
        case lat, lon, time
        case elevationM = "elevation_m"
    }
}

struct SyncTrackJSON: Codable, Sendable, Equatable {
    let externalID: String
    let trackType: String
    let name: String?
    let description: String?
    let points: [SyncPointJSON]

    enum CodingKeys: String, CodingKey {
        case name, description, points
        case externalID = "external_id"
        case trackType = "track_type"
    }
}

struct SyncTracksRequestJSON: Codable, Sendable, Equatable {
    let source: String
    let tracks: [SyncTrackJSON]
}

struct SyncResultJSON: Codable, Sendable, Equatable {
    let externalID: String
    let status: String
    let error: String?

    enum CodingKeys: String, CodingKey {
        case status, error
        case externalID = "external_id"
    }
}

struct SyncResultsJSON: Codable, Sendable, Equatable {
    let results: [SyncResultJSON]
}

struct SyncKnownRequestJSON: Codable, Sendable, Equatable {
    let source: String
    let externalIDs: [String]

    enum CodingKeys: String, CodingKey {
        case source
        case externalIDs = "external_ids"
    }
}

struct SyncKnownJSON: Codable, Sendable, Equatable {
    let known: [String]
    let processing: [String]
}

// Private locations

struct PrivateLocationJSON: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let lon: Double
    let lat: Double
    let radiusM: Int

    enum CodingKeys: String, CodingKey {
        case id, name, lon, lat
        case radiusM = "radius_m"
    }
}

struct PrivateLocationInputJSON: Codable, Sendable, Equatable {
    let name: String
    let lon: Double
    let lat: Double
    let radiusM: Int

    enum CodingKeys: String, CodingKey {
        case name, lon, lat
        case radiusM = "radius_m"
    }
}

// Trips

struct TripTypeStatsJSON: Codable, Sendable, Equatable {
    let trackType: String
    let label: String?
    let count: Int
    let distanceMeters: Double
    let movingSeconds: Int

    enum CodingKeys: String, CodingKey {
        case label, count
        case trackType = "track_type"
        case distanceMeters = "distance_meters"
        case movingSeconds = "moving_seconds"
    }
}

struct TripStatsJSON: Codable, Sendable, Equatable {
    let count: Int
    let distanceMeters: Double
    let movingSeconds: Int
    let byType: [TripTypeStatsJSON]

    enum CodingKeys: String, CodingKey {
        case count
        case distanceMeters = "distance_meters"
        case movingSeconds = "moving_seconds"
        case byType = "by_type"
    }
}

struct TripJSON: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let description: String?
    let from: String?
    let trackIDs: [String]
    let stats: TripStatsJSON

    enum CodingKeys: String, CodingKey {
        case id, name, description, from, stats
        case trackIDs = "track_ids"
    }
}

struct TripsJSON: Codable, Sendable, Equatable {
    let trips: [TripJSON]
}

/// A new Trip, with its first trackIDs.
struct TripCreateJSON: Codable, Sendable, Equatable {
    let name: String
    let description: String
    let trackIDs: [String]

    enum CodingKeys: String, CodingKey {
        case name, description
        case trackIDs = "track_ids"
    }
}

/// A rename: both fields every time, an empty description clearing it.
struct TripInputJSON: Codable, Sendable, Equatable {
    let name: String
    let description: String
}

struct TripTracksJSON: Codable, Sendable, Equatable {
    let trackIDs: [String]

    enum CodingKeys: String, CodingKey {
        case trackIDs = "track_ids"
    }
}

struct TripSendJSON: Codable, Sendable, Equatable {
    let id: String
    let tripName: String
    let from: String
    let trackCount: Int

    enum CodingKeys: String, CodingKey {
        case id, from
        case tripName = "trip_name"
        case trackCount = "track_count"
    }
}

struct TripCopyingJSON: Codable, Sendable, Equatable {
    let tripName: String
    let from: String

    enum CodingKeys: String, CodingKey {
        case from
        case tripName = "trip_name"
    }
}

struct TripInboxJSON: Codable, Sendable, Equatable {
    let sends: [TripSendJSON]
    let copying: [TripCopyingJSON]
}

// Photos

struct PhotoJSON: Codable, Sendable, Equatable {
    let id: String
    let trackID: String
    let takenAt: String?
    let routeAt: String
    let timezone: String
    let lon: Double?
    let lat: Double?
    let caption: String?
    let width: Int
    let height: Int
    let url: String
    let thumbURL: String

    enum CodingKeys: String, CodingKey {
        case id, timezone, lon, lat, caption, width, height, url
        case trackID = "track_id"
        case takenAt = "taken_at"
        case routeAt = "route_at"
        case thumbURL = "thumb_url"
    }
}

struct PhotosJSON: Codable, Sendable, Equatable {
    let photos: [PhotoJSON]
}

struct PhotoPlaceRequestJSON: Codable, Sendable, Equatable {
    let trackID: String
    let takenAt: String?
    let takenLocal: String?
    let lat: Double?
    let lon: Double?

    enum CodingKeys: String, CodingKey {
        case lat, lon
        case trackID = "track_id"
        case takenAt = "taken_at"
        case takenLocal = "taken_local"
    }
}

struct PhotoPlaceJSON: Codable, Sendable, Equatable {
    let routeAt: String

    enum CodingKeys: String, CodingKey {
        case routeAt = "route_at"
    }
}

/// A field left nil is left out, and so isn't changed.
struct PhotoPatchJSON: Codable, Sendable, Equatable {
    let caption: String?
    let routeAt: String?

    enum CodingKeys: String, CodingKey {
        case caption
        case routeAt = "route_at"
    }
}

// Spots

struct SpotJSON: Codable, Sendable, Equatable {
    let id: Int
    let category: String
    let name: String?
    let address: String?
    let description: String?
    let inscription: String?
    let memorial: String?
    let startDate: String?
    let wikipedia: String?
    let lon: Double
    let lat: Double

    enum CodingKeys: String, CodingKey {
        case id, category, name, address, description, inscription, memorial, wikipedia, lon, lat
        case startDate = "start_date"
    }
}

struct SpotsInAreaJSON: Codable, Sendable, Equatable {
    let spots: [SpotJSON]
    let total: Int
}

/// A GeoJSON MultiPolygon: polygons, each rings, each `[lon, lat]` points.
struct MultiPolygonJSON: Codable, Sendable, Equatable {
    let coordinates: [[[[Double]]]]
}

/// `GET /v2/spots/{id}`: the place's own fields beside its area, in one object.
struct SpotDetailJSON: Codable, Sendable, Equatable {
    let id: Int
    let category: String
    let name: String?
    let address: String?
    let description: String?
    let inscription: String?
    let memorial: String?
    let startDate: String?
    let wikipedia: String?
    let lon: Double
    let lat: Double
    let area: MultiPolygonJSON
    let capturedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, category, name, address, description, inscription, memorial, wikipedia, lon, lat, area
        case startDate = "start_date"
        case capturedAt = "captured_at"
    }
}

struct SpotCaptureJSON: Codable, Sendable, Equatable {
    let spotID: Int
    let capturedAt: String

    enum CodingKeys: String, CodingKey {
        case spotID = "spot_id"
        case capturedAt = "captured_at"
    }
}

struct SpotCapturesJSON: Codable, Sendable, Equatable {
    let captures: [SpotCaptureJSON]
}

struct SpotCaptureRequestJSON: Codable, Sendable, Equatable {
    let lat: Double
    let lon: Double
}
