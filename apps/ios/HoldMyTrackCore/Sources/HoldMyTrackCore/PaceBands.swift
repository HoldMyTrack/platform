/// The focused activity's pace bands (root docs/SPEC.md FR-4.8), as
/// `GET /v1/activities/{id}/track-metrics` gives them: the server bands every synced activity, so
/// the app only draws the runs.
public struct TrackMetrics: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public let lon: Double
        public let lat: Double

        public init(lon: Double, lat: Double) {
            self.lon = lon
            self.lat = lat
        }
    }

    /// Points start...end all in band, slowest 0; neighbouring runs share their boundary point,
    /// so the colored pieces join without a gap.
    public struct Band: Equatable, Sendable {
        public let band: Int
        public let start: Int
        public let end: Int

        public init(band: Int, start: Int, end: Int) {
            (self.band, self.start, self.end) = (band, start, end)
        }
    }

    public let activityID: String
    public let points: [Point]
    public let bands: [Band]

    public init(activityID: String, points: [Point], bands: [Band]) {
        (self.activityID, self.points, self.bands) = (activityID, points, bands)
    }

    init(_ json: TrackMetricsJSON) {
        activityID = json.activityID
        points = json.points.map { Point(lon: $0.lon, lat: $0.lat) }
        bands = json.bands.map { Band(band: $0.band, start: $0.start, end: $0.end) }
    }
}

/// What the map's `track-bands` group draws, the web's bandsGroup.ts and Android's PaceBands.
public enum PaceBands {
    /// The layers document's group and its GeoJSON source.
    public static let group = "track-bands"

    /// Drawn while the focused activity's track is: its own metrics, and the track not hidden,
    /// filtered out or Pending (PanelState.mapHidden), whose metrics would show the old points.
    public static func drawn(_ metrics: TrackMetrics?, focused: String?, mapHidden: Set<String>) -> TrackMetrics? {
        guard let metrics, let focused, metrics.activityID == focused, !mapHidden.contains(focused) else { return nil }
        return metrics
    }

    /// The source's data: one line per run with its `band`, which the layer colors, and the whole
    /// route in recording order marked `route`, which carries the direction arrows: on the runs
    /// they'd bunch wherever the pace changes often. Nil metrics are no lines.
    public static func features(_ metrics: TrackMetrics?) -> JSONValue {
        var features: [JSONValue] = []
        if let metrics {
            let points = metrics.points
            for run in metrics.bands where run.start >= 0 && run.end < points.count && run.start < run.end {
                features.append(feature(points[run.start...run.end], ["band": .number(Double(run.band))]))
            }
            if points.count >= 2 { features.append(feature(points[...], ["route": .bool(true)])) }
        }
        return .object(["type": .string("FeatureCollection"), "features": .array(features)])
    }

    /// The legend's colors, slowest first: the group's `band-N` entries in N's order.
    public static func colors(_ document: LayersDocument) -> [String] {
        let legend = document.groups.first { $0.id == group }?.legend ?? [:]
        return legend.keys.filter { $0.hasPrefix("band-") }
            .sorted { Int($0.dropFirst(5)) ?? 0 < Int($1.dropFirst(5)) ?? 0 }
            .compactMap { legend[$0] }
    }

    private static func feature(_ points: ArraySlice<TrackMetrics.Point>, _ properties: [String: JSONValue]) -> JSONValue {
        .object([
            "type": .string("Feature"),
            "properties": .object(properties),
            "geometry": .object([
                "type": .string("LineString"),
                "coordinates": .array(points.map { .array([.number($0.lon), .number($0.lat)]) }),
            ]),
        ])
    }
}
