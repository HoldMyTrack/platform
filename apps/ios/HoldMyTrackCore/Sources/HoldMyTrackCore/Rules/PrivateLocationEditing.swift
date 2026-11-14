import Foundation

/// The Private location editor's decisions (root docs/SPEC.md FR-8.1,
/// apps/android/docs/SPEC.md FR-2.7), the web's PrivateLocationsPanel and privateLocations.ts: a new circle's size and
/// where the camera goes, the radius's steps, whether a draft differs from what's saved, what a
/// tap on the circles hit, and each circle's outline on the map.
public enum PrivateLocationEditing {
    /// A Private location being edited: a saved one (id set) or a new one.
    public struct Draft: Equatable, Sendable {
        public let id: String?
        public var name: String
        public var lon: Double
        public var lat: Double
        public var radiusM: Int

        public init(id: String?, name: String, lon: Double, lat: Double, radiusM: Int) {
            self.id = id
            self.name = name
            self.lon = lon
            self.lat = lat
            self.radiusM = radiusM
        }

        public init(_ location: PrivateLocation) {
            self.init(id: location.id, name: location.name, lon: location.lon, lat: location.lat, radiusM: location.radiusM)
        }

        /// A new one at the map's centre.
        public static func new(lon: Double, lat: Double) -> Draft {
            Draft(id: nil, name: "", lon: lon, lat: lat, radiusM: defaultRadiusM)
        }
    }

    public static let defaultRadiusM = 200
    /// The radius control's step.
    public static let stepM = 10
    /// Below this zoom a new circle flies in first: at country scale 200 m is under a pixel.
    public static let minPlaceZoom = 12.0
    /// Where a saved one opens at least, and a new one lands from too far out.
    public static let openZoom = 14.0
    /// From the zoom tracks start at, like everything but Fog (root docs/SPEC.md FR-4.15).
    public static let minZoom = PhotoMarkers.tracksMinZoom

    /// A radius from the control, on its step and within the server's bounds.
    public static func radius(_ value: Double) -> Int {
        let range = PrivateLocation.radiusRange
        let stepped = Int((value / Double(stepM)).rounded()) * stepM
        return min(max(stepped, range.lowerBound), range.upperBound)
    }

    /// The zoom a new circle is placed at, from zoom: in to openZoom from below minPlaceZoom,
    /// else where it is.
    public static func placeZoom(_ zoom: Double) -> Double { zoom < minPlaceZoom ? openZoom : zoom }

    /// The zoom a saved one opens at: never out.
    public static func openZoom(_ zoom: Double) -> Double { max(zoom, openZoom) }

    /// Whether draft would change anything, the web's `sameDraft`: a new one always does, and a
    /// name is compared trimmed.
    public static func dirty(_ draft: Draft, saved: [PrivateLocation]) -> Bool {
        guard let id = draft.id, let s = saved.first(where: { $0.id == id }) else { return true }
        return draft.name.trimmingCharacters(in: .whitespacesAndNewlines) != s.name
            || draft.lon != s.lon || draft.lat != s.lat || draft.radiusM != s.radiusM
    }

    /// What a tap on the circles hit.
    public enum Hit: Equatable, Sendable { case selected, saved(String), empty }

    /// The hit from the features under a tap, each with its id ("" for the draft's) and whether
    /// it's the one being edited, the web's click order: the circle being edited wins where
    /// they overlap.
    public static func hit(_ features: [(id: String, selected: Bool)]) -> Hit {
        if features.contains(where: \.selected) { return .selected }
        return features.first { !$0.id.isEmpty }.map { .saved($0.id) } ?? .empty
    }

    static let earthRadiusM = 6_371_008.8

    /// The circle as a closed ring of (lon, lat), drawn from points at a true ground distance so
    /// it matches the server's haversine clip, not a screen circle that stretches with latitude.
    public static func ring(lon: Double, lat: Double, radiusM: Int, steps: Int = 64) -> [(lon: Double, lat: Double)] {
        let lat1 = lat * .pi / 180, lon1 = lon * .pi / 180
        let d = Double(radiusM) / earthRadiusM
        return (0...steps).map { i in
            let bearing = 2 * .pi * Double(i) / Double(steps)
            let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(bearing))
            let lon2 = lon1 + atan2(sin(bearing) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))
            return (lon2 * 180 / .pi, lat2 * 180 / .pi)
        }
    }
}