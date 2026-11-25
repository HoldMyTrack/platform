import Foundation

/// The Sync tab's recordings on the map (apps/android/docs/SPEC.md FR-3.2): each listed one
/// dashed, drawn from the phone's own points since none is on the server yet, and the one picked
/// on the list or the map solid over a halo in its pace bands, as the layers document draws a
/// focused track. One group added to the document, styled from its `casing`, `track`, `focused`
/// and `pace-bands` layers, with a GeoJSON source for the lines and one for the bands. The lines
/// are the simplified ones (Simplify), the bands worked out on the phone (RecordedTrack.metrics).
public enum SyncLines {
    public static let group = "sync-candidates"
    static let haloID = "sync-candidates-halo"
    public static let lineID = "sync-candidates-line"
    public static let highlightID = "sync-candidates-highlight"
    public static let bandsSource = "sync-candidates-bands"
    static let bandsID = "sync-candidates-bands"

    /// document with the group added under the labels; unchanged when it has no track layers.
    public static func adding(to document: LayersDocument) -> LayersDocument {
        let layers = document.groups.flatMap(\.layers)
        func role(_ name: String) -> JSONValue? { layers.first { $0["metadata"]?["holdmytrack:role"]?.string == name } }
        guard let track = role("track"), let casing = role("casing"), let focused = role("focused"), let paceBands = role("pace-bands"),
              !document.groups.contains(where: { $0.id == group }) else { return document }
        func layer(_ id: String, role: String?, layout: JSONValue?, paint: JSONValue?, source: String = group, filter: JSONValue? = nil) -> JSONValue {
            var spec: [String: JSONValue] = [
                "id": .string(id), "type": .string("line"), "source": .string(source),
                "layout": layout ?? .object([:]), "paint": paint ?? .object([:]),
            ]
            if let role { spec["filter"] = .array([.string("=="), .array([.string("get"), .string("role")]), .string(role)]) }
            if let filter { spec["filter"] = filter }
            if let minzoom = track["minzoom"] { spec["minzoom"] = minzoom }
            return .object(spec)
        }
        let dashed: JSONValue = .object([
            "line-color": track["paint"]?["line-color"] ?? .string("#b07e2e"),
            "line-width": .number(3), "line-opacity": .number(0.85),
            "line-dasharray": .array([.number(1.5), .number(1.5)]),
        ])
        var document = document
        document.groups.append(LayersDocument.Group(
            id: group, placement: .beneathLabels, lifts: [],
            sources: [group: .object(["type": .string("geojson")]), bandsSource: .object(["type": .string("geojson")])],
            layers: [
                layer(haloID, role: "highlight", layout: casing["layout"], paint: casing["paint"]),
                layer(lineID, role: "line", layout: .object(["line-cap": .string("butt"), "line-join": .string("round")]), paint: dashed),
                layer(highlightID, role: "highlight", layout: focused["layout"], paint: focused["paint"]),
                layer(bandsID, role: nil, layout: paceBands["layout"], paint: paceBands["paint"], source: bandsSource, filter: paceBands["filter"]),
            ],
            legend: [:]
        ))
        return document
    }

    /// A recording's route as drawn: simplified and banded once, for every redraw after.
    public struct Shape: Equatable, Sendable {
        public let id: String
        /// How many points the route had, so one that changed is shaped again.
        public let points: Int
        public let drawn: [RecordedPoint]
        public let metrics: RouteMetrics

        public init(_ track: RecordedTrack) {
            id = track.id
            points = track.points.count
            drawn = track.drawnPoints
            metrics = track.metrics(kept: drawn)
        }
    }

    /// What was last drawn: the same rows and pick draw nothing new.
    public struct Drawn: Equatable, Sendable {
        public let ids: [String]
        public let highlight: String?

        public init(ids: [String], highlight: String?) {
            self.ids = ids
            self.highlight = highlight
        }
    }

    /// The lines for shapes, highlight's last so it's drawn over its neighbours; one with fewer
    /// than two points has no line.
    public static func features(_ shapes: [Shape], highlight: String?) -> JSONValue {
        let ordered = shapes.filter { $0.id != highlight } + shapes.filter { $0.id == highlight }
        let features: [JSONValue] = ordered.filter { $0.drawn.count >= 2 }.map { shape -> JSONValue in
            .object([
                "type": .string("Feature"),
                "properties": .object(["role": .string(shape.id == highlight ? "highlight" : "line"), "key": .string(shape.id)]),
                "geometry": .object(["type": .string("LineString"),
                                     "coordinates": .array(shape.drawn.map { .array([.number($0.lon), .number($0.lat)]) })]),
            ])
        }
        return .object(["type": .string("FeatureCollection"), "features": .array(features)])
    }

    /// The box around tracks' points, [west, south, east, north], for the camera; nil with none.
    public static func box(_ tracks: [RecordedTrack]) -> [Double]? {
        let points = tracks.flatMap(\.points)
        guard let first = points.first else { return nil }
        var box = [first.lon, first.lat, first.lon, first.lat]
        for p in points {
            box[0] = min(box[0], p.lon); box[1] = min(box[1], p.lat)
            box[2] = max(box[2], p.lon); box[3] = max(box[3], p.lat)
        }
        return box
    }
}

/// Which waiting rows cover the same stretch of time as each other: the phone's half of the Sync
/// tab's similar-tracks hint (docs/SPEC.md FR-3.5), the server answering for the account's own
/// tracks. A hint only: nothing is unticked, hidden or chosen on the user's behalf (ADR-0039).
/// The rule is the shared `similarSpans`, the server's `overlapMatches`.
public enum SyncSimilar {
    /// The share of the longer span two must have in common.
    public static let minShare = 0.8

    public static func overlaps(_ aStart: Date, _ aEnd: Date, _ bStart: Date, _ bEnd: Date) -> Bool {
        let a = aEnd.timeIntervalSince(aStart), b = bEnd.timeIntervalSince(bStart)
        guard a > 0, b > 0 else { return false }
        let shared = min(aEnd, bEnd).timeIntervalSince(max(aStart, bStart))
        // In whole milliseconds, cut as Android's Duration.toMillis cuts, so a boundary case agrees.
        return (shared * 1000).rounded(.towardZero) >= minShare * (max(a, b) * 1000).rounded(.towardZero)
    }

    /// For each of tracks, by id, the others it overlaps, newest first; one that overlaps
    /// nothing isn't in the answer.
    public static func waiting(_ tracks: [RecordedTrack]) -> [String: [RecordedTrack]] {
        var found: [String: [RecordedTrack]] = [:]
        for (i, a) in tracks.enumerated() {
            for b in tracks[(i + 1)...] where a.id != b.id && overlaps(a.startedAt, a.endedAt, b.startedAt, b.endedAt) {
                found[a.id, default: []].append(b)
                found[b.id, default: []].append(a)
            }
        }
        return found.mapValues { $0.sorted { $0.startedAt > $1.startedAt } }
    }

    /// How many tracks cover track's time, for its ⓘ: the other rows, and the account's track
    /// when the server named one. None for one on its way.
    public static func count(_ track: RecordedTrack, waiting: [String: [RecordedTrack]], onMap: Bool) -> Int {
        track.sent ? 0 : waiting[track.id, default: []].count + (onMap ? 1 : 0)
    }
}


/// The account's track a waiting row overlaps, as the server answered: opened on the map, on its
/// day, from the row's similar-tracks dialog.
public struct TrackOverlap: Equatable, Sendable {
    public let trackID: String
    public let name: String
    public let trackType: String
    public let startedAt: String
    public let timezone: String?

    public init(trackID: String, name: String, trackType: String, startedAt: String, timezone: String?) {
        self.trackID = trackID
        self.name = name
        self.trackType = trackType
        self.startedAt = startedAt
        self.timezone = timezone
    }

    /// The day it started, "2026-11-21", in its own zone, else accountZone, else the phone's: the
    /// day the Tracks tab opens it on.
    public func day(accountZone: String?) -> String? {
        TrackZone.day(startedAt: startedAt, own: timezone, account: accountZone)
    }

    init(_ json: OverlapJSON) {
        self.init(trackID: json.trackID, name: json.name, trackType: json.trackType, startedAt: json.startedAt, timezone: json.timezone)
    }
}