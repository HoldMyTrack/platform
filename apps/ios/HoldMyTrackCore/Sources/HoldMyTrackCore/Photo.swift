import Foundation

/// A saved photo (root docs/SPEC.md FR-15), at its point on its activity's route.
public struct Photo: Equatable, Sendable {
    public let id: String
    public let activityID: String
    /// When it was taken, ISO 8601, formatted in timezone; nil when the photo didn't say.
    public let takenAt: String?
    /// The moment on the route it sits at.
    public let routeAt: String
    public let timezone: String
    /// Where on the route it sits; nil while the route has no point for it (a track not yet drawn).
    public let lon: Double?
    public let lat: Double?
    public let caption: String?
    /// The stored copy's size, in pixels.
    public let width: Int
    public let height: Int
    /// API paths of the stored copy and its thumbnail, which never change.
    public let url: String
    public let thumbURL: String

    public init(
        id: String, activityID: String, takenAt: String? = nil, routeAt: String = "", timezone: String = "",
        lon: Double? = nil, lat: Double? = nil, caption: String? = nil, width: Int = 0, height: Int = 0,
        url: String = "", thumbURL: String = ""
    ) {
        self.id = id
        self.activityID = activityID
        self.takenAt = takenAt
        self.routeAt = routeAt
        self.timezone = timezone
        self.lon = lon
        self.lat = lat
        self.caption = caption
        self.width = width
        self.height = height
        self.url = url
        self.thumbURL = thumbURL
    }

    init(_ json: PhotoJSON) {
        self.init(
            id: json.id, activityID: json.activityID, takenAt: json.takenAt, routeAt: json.routeAt, timezone: json.timezone,
            lon: json.lon, lat: json.lat, caption: json.caption, width: json.width, height: json.height,
            url: json.url, thumbURL: json.thumbURL
        )
    }
}

/// A photo marker's place on the map, with what it shows.
public struct PhotoMarkerItem: Equatable, Sendable {
    public let id: String
    public let lon: Double
    public let lat: Double
    public let caption: String?
    /// The thumbnail's API path.
    public let thumbPath: String

    public init(id: String, lon: Double, lat: Double, caption: String?, thumbPath: String) {
        self.id = id
        self.lon = lon
        self.lat = lat
        self.caption = caption
        self.thumbPath = thumbPath
    }
}

extension PhotoMarkers {
    /// How far a spread group's tap zooms in: where groupSpread is wider than a marker.
    public static let groupMaxZoom = 19.0

    /// Whether markers show for scope: one, and for an activity, its route not hidden.
    public static func shown(_ scope: PhotoScope?, mapHidden: Set<String>) -> Bool {
        switch scope {
        case nil: false
        case .activity(let id): !mapHidden.contains(id)
        case .story: true
        }
    }

    /// The markers for photos in route order: those placed on a route, on routes not hidden.
    public static func items(_ photos: [Photo], mapHidden: Set<String>) -> [PhotoMarkerItem] {
        photos.compactMap { p in
            guard let lon = p.lon, let lat = p.lat, !mapHidden.contains(p.activityID) else { return nil }
            return PhotoMarkerItem(id: p.id, lon: lon, lat: lat, caption: p.caption, thumbPath: p.thumbURL)
        }
    }
}

extension APIClient {
    /// `GET /v1/photos?activity=` or `?story=`: the scope's photos, in route order.
    public func photos(_ scope: PhotoScope) async throws -> [Photo] {
        let item = switch scope {
        case .activity(let id): URLQueryItem(name: "activity", value: id)
        case .story(let id): URLQueryItem(name: "story", value: id)
        }
        let json: PhotosJSON = try decode(try await send("GET", "v1/photos", query: [item]))
        return json.photos.map(Photo.init)
    }
}
